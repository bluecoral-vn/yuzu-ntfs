// SPDX-License-Identifier: GPL-2.0-only
// Offline test-image authoring only; never linked into the driver or app.
#include "config.h"
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <CommonCrypto/CommonDigest.h>
#include "volume.h"
#include "dir.h"
#include "attrib.h"
#include "inode.h"
#include "unistr.h"
#include "runlist.h"

#define CHUNK (128 * 1024)
#define LARGE_SIZE (4 * 1024 * 1024 + 123)
#define FRAGMENT_SIZE (16 * CHUNK)

static void die(const char *message) {
    perror(message);
    exit(EXIT_FAILURE);
}

static void require(int condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "fixturegen: %s\n", message);
        exit(EXIT_FAILURE);
    }
}

static void close_inode(ntfs_inode *ni) {
    if (ntfs_inode_close(ni)) die("ntfs_inode_close");
}

static void close_child(ntfs_inode *ni, ntfs_inode *parent) {
    // Reuse the live parent when synchronizing its index. Opening another copy
    // behind its back would leave the held parent stale.
    if (ntfs_inode_close_in_dir(ni, parent)) die("ntfs_inode_close_in_dir");
}

static ntfschar *unicode(const char *name, int *length) {
    ntfschar *result = NULL;
    *length = ntfs_mbstoucs(name, &result);
    if (*length < 0) die("UTF-8 to UTF-16");
    require(*length <= 255, "name too long");
    return result;
}

static ntfs_inode *create(ntfs_inode *parent, const char *name, mode_t type) {
    int length;
    ntfschar *u = unicode(name, &length);
    ntfs_inode *ni = ntfs_create(parent, const_cpu_to_le32(0), u, length, type);
    free(u);
    if (!ni) die(name);
    return ni;
}

static ntfs_attr *open_data(ntfs_inode *ni, const char *stream) {
    int length = 0;
    ntfschar *u = stream ? unicode(stream, &length) : NULL;
    ntfs_attr *attr = ntfs_attr_open(ni, AT_DATA, u, length);
    free(u);
    if (!attr) die("ntfs_attr_open");
    return attr;
}

// Position-dependent bytes catch offset, truncation and run-boundary errors.
static void pattern(unsigned char *bytes, size_t count, uint64_t offset, unsigned seed) {
    for (size_t i = 0; i < count; i++) {
        uint64_t p = offset + i;
        bytes[i] = (unsigned char)((p * 31 + (p >> 8) * 17 + seed) & 255);
    }
}

static void write_range(ntfs_attr *attr, uint64_t offset, size_t count, unsigned seed) {
    unsigned char bytes[CHUNK];
    pattern(bytes, count, offset, seed);
    if (ntfs_attr_pwrite(attr, offset, count, bytes) != (s64)count) die("ntfs_attr_pwrite");
}

static void write_file(ntfs_inode *parent, const char *name, size_t size, unsigned seed) {
    ntfs_inode *ni = create(parent, name, S_IFREG);
    ntfs_attr *attr = open_data(ni, NULL);
    for (size_t p = 0; p < size; p += CHUNK) {
        size_t count = size - p < CHUNK ? size - p : CHUNK;
        write_range(attr, p, count, seed);
    }
    ntfs_attr_close(attr);
    close_child(ni, parent);
}

static void create_fragmented(ntfs_inode *root) {
    ntfs_inode *file = create(root, "fragmented.bin", S_IFREG);
    ntfs_inode *blocker = create(root, "allocation-blocker.bin", S_IFREG);
    ntfs_attr *a = open_data(file, NULL);
    ntfs_attr *b = open_data(blocker, NULL);
    // Solid allocation interleaves real allocated extents, not sparse holes.
    for (size_t p = 0; p < FRAGMENT_SIZE; p += CHUNK) {
        if (ntfs_attr_truncate_solid(a, p + CHUNK)) die("allocate fragment");
        if (ntfs_attr_map_whole_runlist(a)) die("map fragment allocation");
        runlist_element *last = a->rl;
        require(last && last->length, "missing allocated fragment");
        while (last[1].length) last++;
        // ntfs-3g normally leaves an allocation gap between new files. Put the
        // blocker immediately after this fragment instead, using its allocation
        // search hint (not by rewriting any on-disk allocation metadata).
        root->vol->data1_zone_pos = last->lcn + last->length;
        if (ntfs_attr_truncate_solid(b, p + CHUNK)) die("allocate blocker");
        write_range(a, p, CHUNK, 41);
        write_range(b, p, CHUNK, 73);
    }
    ntfs_attr_close(a);
    ntfs_attr_close(b);
    close_child(file, root);
    close_child(blocker, root);
}

static void create_basic(ntfs_inode *root) {
    write_file(root, "resident.txt", 37, 11);
    write_file(root, "nonresident.bin", LARGE_SIZE, 29);
    create_fragmented(root);
    write_file(root, "ads.txt", 53, 97);
    ntfs_inode *ni = ntfs_pathname_to_inode(root->vol, root, "ads.txt");
    if (!ni) die("ads.txt");
    int length;
    ntfschar *u = unicode("metadata", &length);
    if (ntfs_attr_add(ni, AT_DATA, u, length, NULL, 0)) die("add ADS");
    free(u);
    ntfs_attr *ads = open_data(ni, "metadata");
    write_range(ads, 0, 71, 101);
    ntfs_attr_close(ads);
    close_child(ni, root);
    ni = ntfs_pathname_to_inode(root->vol, root, "resident.txt");
    if (!ni) die("resident.txt");
    u = unicode("resident-hardlink.txt", &length);
    if (ntfs_link(ni, root, u, length)) die("hard link");
    free(u);
    close_child(ni, root);
    ntfs_inode *dir = create(root, "subdir", S_IFDIR);
    write_file(dir, "nested.txt", 127, 131);
    close_child(dir, root);
}

static const char *names[] = {
    "中文-日本語-한국어.txt", "emoji-😀-🦊.txt", "caf\xc3\xa9.txt", "cafe\xcc\x81.txt"
};

static void populate(ntfs_inode *root, const char *mode) {
    if (!strcmp(mode, "basic")) {
        create_basic(root);
    } else if (!strcmp(mode, "bigdir")) {
        for (unsigned i = 0; i < 100000; i++) {
            char name[32];
            snprintf(name, sizeof(name), "file-%06u.txt", i);
            write_file(root, name, 32, i);
        }
    } else {
        for (unsigned i = 0; i < sizeof(names) / sizeof(*names); i++)
            write_file(root, names[i], 64 + i, 151 + i);
    }
}

static unsigned entry_count;
static int first_entry;

static void json_string(FILE *out, const char *string) {
    fputc('"', out);
    for (const unsigned char *p = (const unsigned char *)string; *p; p++) {
        if (*p == '"' || *p == '\\') fputc('\\', out);
        require(*p >= 32, "unexpected control character in manifest path");
        fputc(*p, out);
    }
    fputc('"', out);
}

static void entry_prefix(FILE *out, const char *path) {
    fprintf(out, "%s\n    {\"path\":", first_entry ? "" : ",");
    first_entry = 0;
    entry_count++;
    json_string(out, path);
}

static void verify_file(ntfs_volume *vol, FILE *out, const char *path,
                        const char *stream, size_t size, unsigned seed,
                        int residency, int fragmented) {
    ntfs_inode *ni = ntfs_pathname_to_inode(vol, NULL, path);
    if (!ni) die(path);
    ntfs_attr *attr = open_data(ni, stream);
    require(attr->data_size == (s64)size, "incorrect file size");
    if (residency >= 0)
        require(!!NAttrNonResident(attr) == residency, "incorrect residency");
    unsigned runs = 0;
    if (NAttrNonResident(attr)) {
        if (ntfs_attr_map_whole_runlist(attr)) die("map runlist");
        for (runlist_element *r = attr->rl; r && r->length; r++) {
            require(r->lcn >= 0, "unexpected sparse run");
            runs++;
        }
    }
    if (fragmented) require(runs > 1, "fragmented.bin must have multiple allocated runs");
    unsigned char actual[CHUNK], expected[CHUNK], digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    for (size_t p = 0; p < size; p += CHUNK) {
        size_t count = size - p < CHUNK ? size - p : CHUNK;
        if (ntfs_attr_pread(attr, p, count, actual) != (s64)count) die("verify read");
        pattern(expected, count, p, seed);
        require(!memcmp(actual, expected, count), "readback differs from expected bytes");
        CC_SHA256_Update(&hash, actual, (CC_LONG)count);
    }
    CC_SHA256_Final(digest, &hash);
    char fullpath[512];
    int n = snprintf(fullpath, sizeof(fullpath), "%s%s%s", path, stream ? ":" : "", stream ? stream : "");
    require(n > 0 && n < (int)sizeof(fullpath), "manifest path overflow");
    entry_prefix(out, fullpath);
    fprintf(out, ",\"type\":\"%s\",\"size\":%zu,\"sha256\":\"", stream ? "stream" : "file", size);
    for (unsigned i = 0; i < sizeof(digest); i++) fprintf(out, "%02x", digest[i]);
    fprintf(out, "\",\"mft_record\":%" PRIu64 ",\"data_runs\":%u}", ni->mft_no, runs);
    ntfs_attr_close(attr);
    close_inode(ni);
}

static void verify_manifest(ntfs_volume *vol, const char *mode, const char *manifest) {
    FILE *out = fopen(manifest, "w");
    if (!out) die(manifest);
    fprintf(out, "{\n  \"schema_version\":1,\n  \"generator\":\"ntfs-3g 2022.10.3 / Yuzu fixturegen\",\n  \"entries\":[");
    first_entry = 1;
    if (!strcmp(mode, "basic")) {
        verify_file(vol, out, "/resident.txt", NULL, 37, 11, 0, 0);
        verify_file(vol, out, "/resident-hardlink.txt", NULL, 37, 11, 0, 0);
        verify_file(vol, out, "/nonresident.bin", NULL, LARGE_SIZE, 29, 1, 0);
        verify_file(vol, out, "/fragmented.bin", NULL, FRAGMENT_SIZE, 41, 1, 1);
        verify_file(vol, out, "/allocation-blocker.bin", NULL, FRAGMENT_SIZE, 73, 1, 0);
        verify_file(vol, out, "/ads.txt", NULL, 53, 97, 0, 0);
        verify_file(vol, out, "/ads.txt", "metadata", 71, 101, -1, 0);
        ntfs_inode *dir = ntfs_pathname_to_inode(vol, NULL, "/subdir");
        if (!dir) die("subdir");
        require(!!(dir->mrec->flags & MFT_RECORD_IS_DIRECTORY), "subdir must be a directory");
        entry_prefix(out, "/subdir");
        fprintf(out, ",\"type\":\"directory\",\"size\":0,\"sha256\":null,\"mft_record\":%" PRIu64 "}", dir->mft_no);
        close_inode(dir);
        verify_file(vol, out, "/subdir/nested.txt", NULL, 127, 131, 0, 0);
    } else if (!strcmp(mode, "bigdir")) {
        for (unsigned i = 0; i < 100000; i++) {
            char path[32];
            snprintf(path, sizeof(path), "/file-%06u.txt", i);
            verify_file(vol, out, path, NULL, 32, i, 0, 0);
        }
    } else {
        for (unsigned i = 0; i < sizeof(names) / sizeof(*names); i++) {
            char path[256];
            snprintf(path, sizeof(path), "/%s", names[i]);
            verify_file(vol, out, path, NULL, 64 + i, 151 + i, 0, 0);
        }
    }
    fprintf(out, "\n  ],\n  \"entry_count\":%u\n}\n", entry_count);
    if (fclose(out)) die("close manifest");
}

int main(int argc, char **argv) {
    require(argc == 4, "usage: fixturegen basic|bigdir|names IMAGE MANIFEST");
    const char *mode = argv[1];
    require(!strcmp(mode, "basic") || !strcmp(mode, "bigdir") || !strcmp(mode, "names"), "unknown fixture mode");
    if (ntfs_set_char_encoding("UTF-8")) die("UTF-8 encoding");
    // Preserve both normalization-equivalent names on Darwin.
    if (ntfs_macosx_normalize_filenames(0)) die("disable normalization");
    ntfs_volume *vol = ntfs_mount(argv[2], NTFS_MNT_EXCLUSIVE);
    if (!vol) die("mount image for authoring");
    NVolSetCaseSensitive(vol);
    ntfs_inode *root = ntfs_inode_open(vol, FILE_root);
    if (!root) die("open root");
    populate(root, mode);
    close_inode(root);
    if (ntfs_umount(vol, FALSE)) die("flush image");
    // Verify persisted data through a fresh, strictly read-only mount.
    vol = ntfs_mount(argv[2], NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    if (!vol) die("mount image for verification");
    NVolSetCaseSensitive(vol);
    verify_manifest(vol, mode, argv[3]);
    if (ntfs_umount(vol, FALSE)) die("unmount verified image");
    printf("%s: verified %u manifest entries\n", argv[2], entry_count);
    return EXIT_SUCCESS;
}
