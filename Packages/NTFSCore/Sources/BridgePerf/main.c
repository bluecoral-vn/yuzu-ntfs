/* SPDX-License-Identifier: GPL-2.0-only */
/* Headless bridge workload. Only a private clone is ever opened for writes. */
#include <ntfs_bridge.h>
#include <engine_e2.h>
#include <os/signpost.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <stdatomic.h>

struct device { int fd; _Atomic unsigned long reads, writes, flushes; };
static os_log_t log_handle;
static char directory[] = "/tmp/yuzu-bridge-perf-XXXXXX";
static char copy[512];
static void cleanup(void) { unlink(copy); rmdir(directory); }
static double seconds(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static void require(int error, const char *op) { if (error) { fprintf(stderr, "%s: %s (%d)\n", op, strerror(error), error); exit(1); } }
static int transfer(void *ctx, uint64_t off, void *buf, size_t len, int write) {
    struct device *d = ctx;
    if (write) ++d->writes; else ++d->reads;
    size_t done = 0;
    while (done < len) {
        ssize_t n = write ? pwrite(d->fd, (char *)buf + done, len - done, off + done) : pread(d->fd, (char *)buf + done, len - done, off + done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return n < 0 ? errno : EIO;
        done += n;
    }
    return 0;
}
static int read_device(void *c, uint64_t o, void *b, size_t n) { return transfer(c, o, b, n, 0); }
static int write_device(void *c, uint64_t o, const void *b, size_t n) { return transfer(c, o, (void *)b, n, 1); }
static int flush_device(void *ctx) { struct device *d = ctx; ++d->flushes; return fsync(d->fd) ? errno : 0; }
struct measurement { double time; unsigned long reads, writes, flushes; };
static struct measurement begin(struct device *d) { return (struct measurement){seconds(), d->reads, d->writes, d->flushes}; }
static void report(const char *op, struct device *d, struct measurement m, unsigned long calls, unsigned long extents) {
    printf("%s,%.9f,%lu,%lu,%lu,%lu,%lu\n", op, seconds()-m.time, calls, d->reads-m.reads, d->writes-m.writes, d->flushes-m.flushes, extents); fflush(stdout);
}
#define PROFILE_BEGIN(name) os_signpost_interval_begin(log_handle, OS_SIGNPOST_ID_EXCLUSIVE, name)
#define PROFILE_END(name) os_signpost_interval_end(log_handle, OS_SIGNPOST_ID_EXCLUSIVE, name)
static int entry(void *ctx, const uint16_t *name, size_t n, const nb_attr *a, uint64_t cookie) {
    (void)name; (void)n; (void)cookie;
    if (!a->ref || !a->nlink) return 1;
    ++*(unsigned long *)ctx; return 0;
}
int main(int argc, char **argv) {
    if (argc != 3 || (strcmp(argv[2], "write") && strcmp(argv[2], "readdir"))) { fprintf(stderr,"usage: BridgePerf fixture.img write|readdir\n"); return 2; }
    struct stat st; require(stat(argv[1], &st) ? errno : 0, "stat");
    if (!S_ISREG(st.st_mode)) return 2;
    if (!mkdtemp(directory)) return 1;
    snprintf(copy,sizeof(copy),"%s/image.img",directory);
    atexit(cleanup);
    require(clonefile(argv[1],copy,0) ? errno : 0,"clonefile");
    struct device d = {.fd = open(copy,O_RDWR|O_NOFOLLOW)};
    require(d.fd < 0 ? errno : 0,"open clone");
    nb_blockdev dev = {&d, st.st_size, 512, read_device, write_device, flush_device};
    const nb_engine *api = nb_engine_e2(); nb_volume *v = NULL;
    log_handle = os_log_create("com.bluecoral.yuzuntfs.BridgePerf", "performance");
    puts("operation,seconds,calls,device_reads,device_writes,device_flushes,extents");
    struct measurement m = begin(&d); PROFILE_BEGIN("mount");
    require(api->nb_mount(&dev, !strcmp(argv[2],"write"), &v),"mount");
    PROFILE_END("mount"); report("mount",&d,m,1,0);
    uint64_t root = api->nb_root_ref(v);
    if (!strcmp(argv[2],"readdir")) {
        unsigned long count = 0; m=begin(&d); PROFILE_BEGIN("readdir_attributes");
        require(api->nb_readdir(v,root,0,entry,&count),"readdir");
        PROFILE_END("readdir_attributes"); report("readdir_attributes",&d,m,count,0);
    } else {
        uint16_t name[] = {'p','e','r','f'}; nb_attr a;
        require(api->nb_create(v,root,name,4,NB_FILE,&a),"create");
        size_t block = 1024*1024; unsigned char *payload = malloc(block); if (!payload) return 1;
        memset(payload,0x5a,block);
        double mapping=0,completion=0; unsigned long mapReads=0,mapWrites=0,mapFlush=0,completeReads=0,completeWrites=0,completeFlush=0,extents=0;
        m=begin(&d);
        for (uint64_t off=0; off<64*1024*1024; off+=block) {
            nb_extent e[128]; size_t n=0;
            struct measurement b=begin(&d); PROFILE_BEGIN("blockmap");
            require(api->nb_blockmap(v,a.ref,off,block,1,e,128,&n),"blockmap");
            PROFILE_END("blockmap"); mapping+=seconds()-b.time; mapReads+=d.reads-b.reads; mapWrites+=d.writes-b.writes; mapFlush+=d.flushes-b.flushes; extents+=n;
            for (size_t i=0;i<n;++i) require(write_device(&d,e[i].physical,payload+e[i].logical-off,e[i].length),"raw write");
            b=begin(&d); PROFILE_BEGIN("completeIO");
            require(api->nb_complete_io(v,a.ref,off,block,0,1),"completeIO");
            PROFILE_END("completeIO"); completion+=seconds()-b.time; completeReads+=d.reads-b.reads; completeWrites+=d.writes-b.writes; completeFlush+=d.flushes-b.flushes;
        }
        require(api->nb_sync(v),"sync"); report("sequential_64MiB",&d,m,64,extents);
        printf("blockmap,%.9f,64,%lu,%lu,%lu,%lu\n",mapping,mapReads,mapWrites,mapFlush,extents);
        printf("completeIO,%.9f,64,%lu,%lu,%lu,0\n",completion,completeReads,completeWrites,completeFlush);
        m=begin(&d); PROFILE_BEGIN("small_create_write_close");
        for(unsigned i=0;i<256;++i) {
            char text[32]; snprintf(text,sizeof(text),"small-%04u",i); uint16_t units[32]; size_t len=strlen(text); for(size_t j=0;j<len;++j) units[j]=text[j];
            require(api->nb_create(v,root,units,len,NB_FILE,&a),"small create");
            require(api->nb_hold(v,a.ref),"hold");
            nb_extent e[128]; size_t n=0;
            require(api->nb_blockmap(v,a.ref,0,4096,1,e,128,&n),"small map");
            for(size_t j=0;j<n;++j) require(write_device(&d,e[j].physical,payload+e[j].logical,e[j].length),"small raw write");
            require(api->nb_complete_io(v,a.ref,0,4096,0,1),"small complete");
            require(api->nb_release(v,a.ref),"close");
        }
        require(api->nb_sync(v),"small sync"); PROFILE_END("small_create_write_close"); report("small_create_write_close",&d,m,256,0);
        free(payload);
    }
    m=begin(&d); PROFILE_BEGIN("unmount"); require(api->nb_unmount(v),"unmount"); PROFILE_END("unmount"); report("unmount",&d,m,1,0);
    close(d.fd); require(unlink(copy) ? errno : 0,"unlink clone"); require(rmdir(directory) ? errno : 0,"rmdir");
    return 0;
}
