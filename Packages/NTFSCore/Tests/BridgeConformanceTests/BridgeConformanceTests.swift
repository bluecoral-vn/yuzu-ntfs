// SPDX-License-Identifier: GPL-2.0-only
import Testing
import Foundation
import CryptoKit
import Darwin
import NTFSBridge
import EngineE2

enum Engine: CaseIterable, Sendable {
    case e2
    func api() throws -> nb_engine {
        try #require(nb_engine_e2(), "E2 bridge is not implemented").pointee
    }
}

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
private struct Entry: Decodable { let path: String; let type: String; let size: Int; let sha256: String?; let mft_record: UInt64 }
private struct Manifest: Decodable { let entries: [Entry] }
private func fixture(_ name: String) throws -> URL {
    let url = repository.appendingPathComponent("fixtures/\(name).img")
    try #require(FileManager.default.fileExists(atPath: url.path), "Missing \(url.path); run scripts/make-fixtures.sh")
    return url
}
private func manifest(_ name: String) throws -> [Entry] {
    _ = try fixture(name)
    let url = repository.appendingPathComponent("fixtures/\(name).manifest.json")
    try #require(FileManager.default.fileExists(atPath: url.path), "Missing manifest; run scripts/make-fixtures.sh")
    return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)).entries
}
private func tool(_ name: String, _ arguments: [String]) throws -> Data {
    try autoreleasepool {
    let process = Process()
    let terminated = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in terminated.signal() }
    let executable = repository.appendingPathComponent("tools/bin/\(name)")
    try #require(FileManager.default.isExecutableFile(atPath: executable.path), "Missing ntfsprogs; run scripts/make-fixtures.sh")
    process.executableURL = executable
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    terminated.wait()
    try #require(process.terminationStatus == 0)
    return data
    }
}
private final class DeviceIO {
    let fd: Int32
    private let lock = NSLock()
    private var failingReads = false
    private var writes = 0
    private var flushes = 0
    private var failingNextWrite = false
    init(fd: Int32) { self.fd = fd }
    var failReads: Bool {
        get { lock.withLock { failingReads } }
        set { lock.withLock { failingReads = newValue } }
    }
    var failNextWrite: Bool {
        get { lock.withLock { failingNextWrite } }
        set { lock.withLock { failingNextWrite = newValue } }
    }
    var writeCount: Int { lock.withLock { writes } }
    var flushCount: Int { lock.withLock { flushes } }
    func beginFlush() { lock.withLock { flushes += 1 } }
    func beginWrite() -> Bool {
        lock.withLock {
            writes += 1
            let fail = failingNextWrite
            failingNextWrite = false
            return fail
        }
    }
}

private final class Image {
    let fd: Int32
    let io: DeviceIO
    let url: URL
    let temporary: Bool
    var dev: nb_blockdev
    init(_ name: String, copy: Bool = false) throws {
        let original = try fixture(name)
        temporary = copy
        url = copy ? FileManager.default.temporaryDirectory.appendingPathComponent("yuzu-e2-\(UUID()).img") : original
        if copy { try FileManager.default.copyItem(at: original, to: url) }
        fd = open(url.path, copy ? O_RDWR : O_RDONLY)
        try #require(fd >= 0)
        io = DeviceIO(fd: fd)
        var stat = Darwin.stat()
        try #require(fstat(fd, &stat) == 0)
        dev = nb_blockdev(ctx: Unmanaged.passUnretained(io).toOpaque(), size: UInt64(stat.st_size), sector_size: name == "4kn" ? 4096 : 512, read: { ctx, off, buf, len in
            let io = Unmanaged<DeviceIO>.fromOpaque(ctx!).takeUnretainedValue()
            if io.failReads { return EIO }
            let fd = io.fd
            var done = 0
            while done < len {
                let n = pread(fd, buf!.advanced(by: done), len - done, off_t(off) + off_t(done))
                if n < 0 { if errno == EINTR { continue }; return errno }
                if n == 0 { return EIO }
                done += n
            }
            return 0
        }, write: { ctx, off, buf, len in
            let io = Unmanaged<DeviceIO>.fromOpaque(ctx!).takeUnretainedValue()
            if io.beginWrite() { return EIO }
            let fd = io.fd
            var done = 0
            while done < len {
                let n = pwrite(fd, buf!.advanced(by: done), len - done, off_t(off) + off_t(done))
                if n < 0 { if errno == EINTR { continue }; return errno }
                if n == 0 { return EIO }
                done += n
            }
            return 0
        }, flush: { ctx in
            let io = Unmanaged<DeviceIO>.fromOpaque(ctx!).takeUnretainedValue()
            io.beginFlush()
            return fsync(io.fd) == 0 ? 0 : errno
        })
    }
    deinit { close(fd); if temporary { try? FileManager.default.removeItem(at: url) } }
}
private final class Mounted {
    let image: Image
    let api: nb_engine
    var volume: OpaquePointer?
    init(_ engine: Engine, _ name: String, write: Bool = false) throws {
        image = try Image(name, copy: write)
        api = try engine.api()
        try #require(api.nb_mount!(&image.dev, write ? 1 : 0, &volume) == 0)
        try #require(volume != nil)
    }
    deinit { if let volume { _ = api.nb_unmount!(volume) } }
    func lookup(_ path: String) throws -> nb_attr {
        var attr = nb_attr()
        var ref = api.nb_root_ref!(volume)
        for component in path.split(separator: "/") {
            let units = Array(component.utf16)
            let result = units.withUnsafeBufferPointer { api.nb_lookup!(volume, ref, $0.baseAddress, $0.count, &attr) }
            try #require(result == 0, "lookup \(path): errno \(result)")
            ref = attr.ref
        }
        return attr
    }
    func read(_ attr: nb_attr) throws -> Data {
        var bytes = Data(count: Int(attr.size))
        var got = 0
        let rc = bytes.withUnsafeMutableBytes { api.nb_read!(volume, attr.ref, 0, $0.baseAddress, $0.count, &got) }
        try #require(rc == 0)
        try #require(got == bytes.count)
        return bytes
    }
}

// Bridge counterpart of the real-handler cold-kernel model in CompletionTests:
// READ mappings, not raw disk slack, supply the covering sector cache. Require
// exact request coordinates, overlay the bytes, then persist whole sectors.
private func kernelRMWWrite(_ mounted: Mounted, ref: UInt64, offset: UInt64,
                            payload: Data, extents: some Collection<nb_extent>) throws {
    let sector = UInt64(mounted.image.dev.sector_size)
    var cursor = offset
    for extent in extents {
        try #require(extent.logical == cursor, "WRITE mapping does not start at request")
        try #require(extent.kind == NB_EXT_DATA || extent.kind == NB_EXT_UNINIT)
        try #require(extent.physical % sector == extent.logical % sector)
        cursor += extent.length
    }
    try #require(cursor == offset + UInt64(payload.count))
    let start = offset / sector * sector
    let end = (cursor + sector - 1) / sector * sector
    var attr = nb_attr()
    try #require(mounted.api.nb_getattr!(mounted.volume, ref, 5, &attr) == 0)
    var reads = [nb_extent](repeating: nb_extent(), count: 128), count = 0
    try #require(mounted.api.nb_read_map_during_write!(mounted.volume, ref, start, end - start,
                                                    &reads, reads.count, &count) == 0)
    var cache = Data(count: Int(end - start))
    cursor = start
    for extent in reads.prefix(count) {
        try #require(extent.logical == cursor, "READ mapping does not start at request")
        if extent.kind == NB_EXT_DATA {
            try cache.withUnsafeMutableBytes {
                try #require(pread(mounted.image.fd, $0.baseAddress!.advanced(by: Int(cursor - start)),
                                   Int(extent.length), off_t(extent.physical)) == Int(extent.length))
            }
        } else {
            try #require(extent.kind == NB_EXT_HOLE || extent.kind == NB_EXT_UNINIT)
        }
        cursor += extent.length
    }
    try #require(cursor == end)
    let eof = min(cache.count, Int(attr.size > start ? attr.size - start : 0))
    cache.replaceSubrange(eof..<cache.count, with: repeatElement(0, count: cache.count - eof))
    cache.replaceSubrange(Int(offset - start)..<Int(offset - start) + payload.count, with: payload)
    for extent in extents {
        let within = extent.physical % sector
        let size = Int((within + extent.length + sector - 1) / sector * sector)
        try cache.withUnsafeBytes {
            try #require(pwrite(mounted.image.fd,
                                $0.baseAddress!.advanced(by: Int(extent.logical - within - start)),
                                size, off_t(extent.physical - within)) == size)
        }
    }
}
private final class Listing {
    var names: [String] = []
    var cookie: UInt64 = 0
    var batch = 0
    let limit: Int
    init(limit: Int = .max) { self.limit = limit }
}
private let collect: nb_dirent_cb = { ctx, name, len, _, cookie in
    let listing = Unmanaged<Listing>.fromOpaque(ctx!).takeUnretainedValue()
    listing.names.append(String(decoding: UnsafeBufferPointer(start: name, count: len), as: UTF16.self))
    listing.cookie = cookie
    listing.batch += 1
    return listing.batch == listing.limit ? 1 : 0
}

struct BridgeConformanceTests {
    @Test(arguments: Engine.allCases) func sequentialMappingsReserveAheadWithoutPublishingSizes(engine: Engine) throws {
        let mounted = try Mounted(engine, "basic-512", write: true)
        let name = Array("sequential.bin".utf16)
        var attr = nb_attr(), count = 0
        try #require(mounted.api.nb_create!(mounted.volume, 5, name, name.count, NB_FILE, &attr) == 0)
        var extent = nb_extent()
        try #require(mounted.api.nb_blockmap!(mounted.volume, attr.ref, 0, 1024 * 1024, 1, &extent, 1, &count) == 0)
        try #require(mounted.api.nb_getattr!(mounted.volume, attr.ref, 5, &attr) == 0)
        #expect(attr.size == 0)
        #expect(attr.alloc_size >= 8 * 1024 * 1024)
        let allocation = attr.alloc_size
        let before = mounted.image.io.flushCount
        try #require(mounted.api.nb_blockmap!(mounted.volume, attr.ref, 1024 * 1024, 1024 * 1024, 1, &extent, 1, &count) == 0)
        #expect(mounted.image.io.flushCount == before)
        try #require(mounted.api.nb_getattr!(mounted.volume, attr.ref, 5, &attr) == 0)
        #expect(attr.alloc_size == allocation)
        #expect(attr.size == 0)
        #expect(mounted.api.nb_complete_io!(mounted.volume, attr.ref, 0, 1024 * 1024, EIO, 1) == EIO)
        #expect(try mounted.lookup("/sequential.bin").size == 0)
    }

    @Test(arguments: Engine.allCases) func smallSequentialUpcallsOnLargeFilesReserveAhead(engine: Engine) throws {
        let mounted = try Mounted(engine, "basic-512", write: true)
        let name = Array("short-upcalls.bin".utf16)
        var attr = nb_attr(), count = 0
        try #require(mounted.api.nb_create!(mounted.volume, 5, name, name.count, NB_FILE, &attr) == 0)
        try #require(mounted.api.nb_truncate!(mounted.volume, attr.ref, 1024 * 1024) == 0)
        var extent = nb_extent()
        try #require(mounted.api.nb_blockmap!(mounted.volume, attr.ref, 1024 * 1024, 4096, 1, &extent, 1, &count) == 0)
        try #require(mounted.api.nb_getattr!(mounted.volume, attr.ref, 5, &attr) == 0)
        #expect(attr.alloc_size >= 8 * 1024 * 1024)
        #expect(attr.size == 1024 * 1024)
    }

    @Test(arguments: Engine.allCases) func completionDefersMetadataCheckpointButFlushesPayload(engine: Engine) throws {
        let mounted = try Mounted(engine, "basic-512", write: true)
        let name = Array("deferred.bin".utf16)
        var attr = nb_attr(), count = 0
        try #require(mounted.api.nb_create!(mounted.volume, 5, name, name.count, NB_FILE, &attr) == 0)
        var extent = nb_extent()
        try #require(mounted.api.nb_blockmap!(mounted.volume, attr.ref, 0, 4096, 1, &extent, 1, &count) == 0)
        let payload = Data(repeating: 0x71, count: 4096)
        try #require(payload.withUnsafeBytes { pwrite(mounted.image.fd, $0.baseAddress, $0.count, off_t(extent.physical)) } == payload.count)
        let before = mounted.image.io.flushCount
        try #require(mounted.api.nb_complete_io!(mounted.volume, attr.ref, 0, 4096, 0, 1) == 0)
        #expect(mounted.image.io.flushCount - before == 1)
        #expect(try mounted.lookup("/deferred.bin").size == 4096)
        try #require(mounted.api.nb_sync!(mounted.volume) == 0)
        try #require(mounted.api.nb_unmount!(mounted.volume) == 0)
        mounted.volume = nil
        try #require(mounted.api.nb_mount!(&mounted.image.dev, 0, &mounted.volume) == 0)
        #expect(try mounted.read(mounted.lookup("/deferred.bin")) == payload)
    }

    @Test func shortRawCompletionZerosPartialBlockBeforeVDLPublication() throws {
        let m = try Mounted(.e2, "basic-512", write: true)
        let name = Array("partial-block.bin".utf16)
        var a = nb_attr(), e = nb_extent(), count = 0
        try #require(m.api.nb_create!(m.volume, m.api.nb_root_ref!(m.volume), name, name.count, NB_FILE, &a) == 0)
        try #require(m.api.nb_blockmap!(m.volume, a.ref, 0, 512, 1, &e, 1, &count) == 0)
        let poison = [UInt8](repeating: 0xA5, count: 512)
        try #require(pwrite(m.image.fd, poison, poison.count, off_t(e.physical)) == 512)
        try #require(m.api.nb_complete_io!(m.volume, a.ref, 0, 37, 0, 1) == 0)
        var raw = [UInt8](repeating: 1, count: 512)
        try #require(pread(m.image.fd, &raw, raw.count, off_t(e.physical)) == 512)
        #expect(raw.prefix(37).allSatisfy { $0 == 0xA5 })
        #expect(raw.dropFirst(37).allSatisfy { $0 == 0 })
    }

    @Test func midBlockVDLMapsAlignedAndPersistsZeros() throws {
        let m = try Mounted(.e2, "basic-512", write: true)
        var a = try m.lookup("resident.txt")
        try #require(m.api.nb_truncate!(m.volume, a.ref, 37) == 0)
        try #require(m.api.nb_truncate!(m.volume, a.ref, 8192) == 0)
        var extents = [nb_extent](repeating: nb_extent(), count: 16), count = 0
        for write: Int32 in [0, 1] {
            try #require(m.api.nb_blockmap!(m.volume, a.ref, 0, 8192, write, &extents, 16, &count) == 0)
            for e in extents.prefix(count) {
                #expect(e.logical % 512 == 0)
                #expect(e.length % 512 == 0)
            }
        }
        try #require(m.api.nb_getattr!(m.volume, a.ref, a.parent_ref, &a) == 0)
        let bytes = try m.read(a)
        #expect(bytes.dropFirst(37).allSatisfy { $0 == 0 })
        try #require(m.api.nb_unmount!(m.volume) == 0); m.volume = nil
        try #require(m.api.nb_mount!(&m.image.dev, 0, &m.volume) == 0)
        let ro = try m.lookup("resident.txt")
        #expect(ro.flags & UInt32(NB_UNALIGNED_VDL) != 0)
        let writes = m.image.io.writeCount
        #expect(m.api.nb_blockmap!(m.volume, ro.ref, 0, 8192, 0, &extents, 16, &count) == ENOTSUP)
        #expect(m.image.io.writeCount == writes)
        #expect(try m.read(m.lookup("resident.txt")) == bytes)
    }

    @Test func pageRoundedReadPastAllocationReturnsZeroTail() throws {
        let m = try Mounted(.e2, "basic-512")
        let a = try m.lookup("nonresident.bin")
        var extents = [nb_extent](repeating: nb_extent(), count: 128), count = 0
        let start = a.alloc_size - 512
        try #require(m.api.nb_blockmap!(m.volume, a.ref, start, 8704, 0, &extents, 128, &count) == 0)
        #expect(extents.prefix(count).reduce(0) { $0 + $1.length } == 8704)
        let last = try #require(extents.prefix(count).last)
        #expect(last.logical == a.alloc_size)
        #expect(last.length == 8192)
        #expect(last.kind == NB_EXT_HOLE)
        try #require(m.api.nb_blockmap!(m.volume, a.ref, a.alloc_size + 4096, 4096, 0, &extents, 128, &count) == 0)
        #expect(count == 1 && extents[0].kind == NB_EXT_HOLE)
        #expect(m.image.io.writeCount == 0)
    }

    @Test func bufferedGapGrowthStaysWritableAndNonSparse() throws {
        let m = try Mounted(.e2, "basic-512", write: true)
        let name = Array("buffered-gap.bin".utf16)
        var a = nb_attr()
        try #require(m.api.nb_create!(m.volume, 5, name, name.count, NB_FILE, &a) == 0)
        var byte: UInt8 = 0x6a
        try #require(m.api.nb_write!(m.volume, a.ref, 1 << 20, &byte, 1) == 0)
        try #require(m.api.nb_getattr!(m.volume, a.ref, 5, &a) == 0)
        #expect(a.flags & UInt32(NB_SPARSE) == 0)
        #expect(m.api.nb_write!(m.volume, a.ref, (1 << 20) + 1, &byte, 1) == 0)
        var expected = Data(count: (1 << 20) + 2)
        expected[1 << 20] = byte; expected[(1 << 20) + 1] = byte
        try #require(m.api.nb_getattr!(m.volume, a.ref, 5, &a) == 0)
        #expect(try m.read(a) == expected)
    }
    @Test func sizeOnlyGrowthUpdatesModificationAndChangeTimes() throws {
        let m = try Mounted(.e2, "basic-512", write: true)
        let before = try m.lookup("/nonresident.bin")
        usleep(2000)
        try #require(m.api.nb_truncate!(m.volume, before.ref, before.size + 4096) == 0)
        var after = nb_attr()
        try #require(m.api.nb_getattr!(m.volume, before.ref, 5, &after) == 0)
        #expect(after.mtime > before.mtime)
        #expect(after.ctime > before.ctime)
    }
    @Test func disposePerformsNoDeviceWrites() throws {
        let m = try Mounted(.e2, "basic-512", write: true)
        let a = try m.lookup("/nonresident.bin")
        var byte: UInt8 = 1
        try #require(m.api.nb_write!(m.volume, a.ref, 0, &byte, 1) == 0)
        let before = m.image.io.writeCount
        _ = m.api.nb_dispose!(m.volume); m.volume = nil
        #expect(m.image.io.writeCount == before)
    }
    @Test func freeSpaceInitializationFailureRemainsTerminal() throws {
        let image = try Image("basic-512", copy: true)
        var volume: OpaquePointer?
        let api = try Engine.e2.api()
        let start = Date()
        let result = nb_e2_test_mount(&image.dev, 1, UInt32(NB_E2_FAIL_FREE_INIT), &volume)
        defer { if let volume { _ = api.nb_unmount!(volume) } }
        if result == 0 {
            var state = nb_stat(), error: Int32 = 0
            repeat {
                error = api.nb_statfs!(volume, &state)
                if error == 0 { Thread.sleep(forTimeInterval: 0.001) }
            } while error == 0 && Date().timeIntervalSince(start) < 5
            #expect(error == ENOMEM)
            let name = Array("must-not-create".utf16)
            var attr = nb_attr()
            #expect(api.nb_create!(volume, 5, name, name.count, NB_FILE, &attr) == ENOMEM)
        } else {
            #expect(result == ENOMEM)
            #expect(volume == nil)
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func mountAndStatfsDoNotJoinBackgroundBitmapScan() throws {
        let image = try Image("basic-512", copy: true)
        var volume: OpaquePointer?
        let api = try Engine.e2.api()
        let start = Date()
        try #require(nb_e2_test_mount(&image.dev, 1, UInt32(NB_E2_DELAY_FREE_INIT), &volume) == 0)
        defer { if let volume { _ = api.nb_unmount!(volume) } }
        var state = nb_stat()
        try #require(api.nb_statfs!(volume, &state) == 0)
        #expect(Date().timeIntervalSince(start) < 0.25)
        #expect(state.free_blocks == 0) // Conservative estimate, never a false capacity promise.
        Thread.sleep(forTimeInterval: 0.4)
        try #require(api.nb_statfs!(volume, &state) == 0)
        #expect(state.free_blocks > 0)
    }
    @Test func failedCreatePromotionRollsBackNamespace() throws {
        let m = try Mounted(.e2, "basic-512", write: true)
        let name = Array("promotion-failure.bin".utf16)
        var a = nb_attr()
        try #require(nb_e2_test_fault(m.volume, UInt32(NB_E2_FAIL_PROMOTION)) == 0)
        #expect(m.api.nb_create!(m.volume, 5, name, name.count, NB_FILE, &a) == ENOMEM)
        #expect(m.api.nb_lookup!(m.volume, 5, name, name.count, &a) == ENOENT)
    }
    @Test func failedMappingAllocationNeverPublishesEOF() throws {
        let m = try Mounted(.e2, "basic-512", write: true)
        let name = Array("allocation-failure.bin".utf16)
        var a = nb_attr()
        try #require(m.api.nb_create!(m.volume, 5, name, name.count, NB_FILE, &a) == 0)
        try #require(nb_e2_test_fault(m.volume, UInt32(NB_E2_FAIL_AFTER_ALLOCATION)) == 0)
        var extent = nb_extent(), count = 0
        #expect(m.api.nb_blockmap!(m.volume, a.ref, 0, 65536, 1, &extent, 1, &count) == ENOMEM)
        #expect(count == 0)
        try #require(m.api.nb_getattr!(m.volume, a.ref, 5, &a) == 0)
        #expect(a.size == 0)
        try #require(m.api.nb_unmount!(m.volume) == 0); m.volume = nil
        try #require(m.api.nb_mount!(&m.image.dev, 0, &m.volume) == 0)
        #expect(try m.lookup("/allocation-failure.bin").size == 0)
    }
    @Test func ordinaryGrowthKeepsNonSparseAllocationAndSupportsLaterKOIO() throws {
        let m = try Mounted(.e2, "basic-512", write: true)
        let name = Array("ordinary-growth.bin".utf16)
        var a = nb_attr()
        try #require(m.api.nb_create!(m.volume, 5, name, name.count, NB_FILE, &a) == 0)
        try #require(m.api.nb_truncate!(m.volume, a.ref, 65536) == 0)
        try #require(m.api.nb_getattr!(m.volume, a.ref, 5, &a) == 0)
        #expect(a.flags & UInt32(NB_SPARSE) == 0)
        #expect(a.alloc_size >= a.size)
        #expect(try m.read(a) == Data(count: 65536))
        var extent = nb_extent(), count = 0
        try #require(m.api.nb_blockmap!(m.volume, a.ref, 4096, 512, 1, &extent, 1, &count) == 0)
        let payload = Data(repeating: 0xa6, count: 512)
        try #require(payload.withUnsafeBytes { pwrite(m.image.fd, $0.baseAddress, $0.count, off_t(extent.physical)) } == payload.count)
        try #require(m.api.nb_complete_io!(m.volume, a.ref, 4096, 512, 0, 1) == 0)
        try #require(m.api.nb_unmount!(m.volume) == 0); m.volume = nil
        try #require(m.api.nb_mount!(&m.image.dev, 0, &m.volume) == 0)
        var expected = Data(count: 65536); expected.replaceSubrange(4096..<4608, with: payload)
        #expect(try m.read(m.lookup("/ordinary-growth.bin")) == expected)
    }
    @Test func failedRawWriteInvalidatesCachedPrefixWithoutChangingSize() throws {
        let m = try Mounted(.e2, "basic-512", write: true)
        let a = try m.lookup("/nonresident.bin")
        var cached = [UInt8](repeating: 0, count: 13), got = 0
        try #require(m.api.nb_read!(m.volume, a.ref, 1, &cached, cached.count, &got) == 0)
        var extents = [nb_extent](repeating: nb_extent(), count: 4), count = 0
        try #require(m.api.nb_blockmap!(m.volume, a.ref, 0, 4096, 1, &extents, 4, &count) == 0)
        let payload = [UInt8](repeating: 0xa7, count: 512)
        try #require(pwrite(m.image.fd, payload, payload.count, off_t(extents[0].physical)) == payload.count)
        #expect(m.api.nb_complete_io!(m.volume, a.ref, 0, 4096, EIO, 1) == EIO)
        try #require(m.api.nb_read!(m.volume, a.ref, 1, &cached, cached.count, &got) == 0)
        #expect(cached == [UInt8](repeating: 0xa7, count: 13))
        var current = nb_attr()
        try #require(m.api.nb_getattr!(m.volume, a.ref, 5, &current) == 0)
        #expect(current.size == a.size)
    }
    @Test func streamPublicationLifetimeAndAttributes() throws {
        let m = try Mounted(.e2, "basic-512")
        let a = try m.lookup("/ads.txt:metadata")
        #expect(m.api.nb_hold!(m.volume, a.ref) == 0)
        var current = nb_attr()
        #expect(m.api.nb_getattr!(m.volume, a.ref, 5, &current) == 0)
        #expect(current.ref == a.ref)
        #expect(current.size == 71)
        #expect(current.flags & UInt32(NB_READ_ONLY) != 0)
        #expect(try m.read(a).count == 71)
        #expect(m.api.nb_release!(m.volume, a.ref) == 0)
    }
    @Test func reservedMetadataCannotBeMutated() throws {
        let m = try Mounted(.e2, "basic-512", write: true)
        let a = try m.lookup("/$Bitmap")
        let before = m.image.io.writeCount
        var extents = [nb_extent](repeating: nb_extent(), count: 4), count = 0
        let byte: [UInt8] = [0x55]
        #expect(m.api.nb_write!(m.volume, a.ref, 0, byte, 1) == EPERM)
        #expect(m.api.nb_truncate!(m.volume, a.ref, 0) == EPERM)
        #expect(m.api.nb_blockmap!(m.volume, a.ref, 0, 512, 1, &extents, 4, &count) == EPERM)
        #expect(m.api.nb_complete_io!(m.volume, a.ref, 0, 512, 0, 1) == EPERM)
        var attrs = nb_attr()
        #expect(m.api.nb_setattr!(m.volume, a.ref, &attrs, UInt32(NB_SET_MTIME)) == EPERM)
        #expect(m.image.io.writeCount == before)
    }
    @Test(arguments: Engine.allCases) func newFilesAndShrunkFilesAcceptKOIOWrites(engine: Engine) throws {
        let m = try Mounted(engine, "basic-512", write: true)
        let root = m.api.nb_root_ref!(m.volume), name = Array("koio-new".utf16)
        var a = nb_attr()
        try #require(m.api.nb_create!(m.volume, root, name, name.count, UInt32(NB_FILE), &a) == 0)
        #expect(a.flags & UInt32(NB_RESIDENT) == 0)
        try #require(m.api.nb_truncate!(m.volume, a.ref, 4096) == 0)
        try #require(m.api.nb_truncate!(m.volume, a.ref, 0) == 0)
        try #require(m.api.nb_getattr!(m.volume, a.ref, root, &a) == 0)
        #expect(a.size == 0)
        var extents = [nb_extent](repeating: nb_extent(), count: 4), count = 0
        #expect(m.api.nb_blockmap!(m.volume, a.ref, 0, 1000003, 1, &extents, 4, &count) == 0)
        #expect(count > 0)
        let payload = Data(repeating: 0x5a, count: 1000003)
        try kernelRMWWrite(m, ref: a.ref, offset: 0, payload: payload, extents: extents.prefix(count))
        try #require(m.api.nb_complete_io!(m.volume, a.ref, 0, UInt64(payload.count), 0, 1) == 0)
        try #require(m.api.nb_unmount!(m.volume) == 0); m.volume = nil
        try #require(m.api.nb_mount!(&m.image.dev, 0, &m.volume) == 0)
        #expect(try m.read(m.lookup("koio-new")) == payload)
    }

    @Test(arguments: Engine.allCases) func residentMappingPromotesWithoutLosingBytes(engine: Engine) throws {
        let m = try Mounted(engine, "basic-512", write: true)
        let a = try m.lookup("resident.txt"), before = try m.read(a)
        var extents = [nb_extent](repeating: nb_extent(), count: 4), count = 0
        // RW read mapping also promotes, without changing EOF or payload.
        try #require(m.api.nb_blockmap!(m.volume, a.ref, 0, a.size, 0, &extents, 4, &count) == 0)
        try #require(m.api.nb_sync!(m.volume) == 0)
        let info = String(decoding: try tool("ntfsinfo", ["-f", "-m", m.image.url.path]), as: UTF8.self)
        let flags = info.split(separator: "\n").first { $0.contains("Volume Flags:") }
        // TT's ntfs_sync_fs clears the dirty flag at a successful checkpoint.
        #expect(flags?.contains("0x0000") == true)
        try #require(m.api.nb_blockmap!(m.volume, a.ref, a.size, 7, 1, &extents, 4, &count) == 0)
        let marker = Data(repeating: 0xa5, count: 7)
        try #require(count == 1)
        try kernelRMWWrite(m, ref: a.ref, offset: a.size, payload: marker, extents: extents.prefix(count))
        try #require(m.api.nb_complete_io!(m.volume, a.ref, a.size, 7, 0, 1) == 0)
        try #require(m.api.nb_unmount!(m.volume) == 0); m.volume = nil
        try #require(m.api.nb_mount!(&m.image.dev, 0, &m.volume) == 0)
        let persisted = try m.lookup("resident.txt")
        #expect(try m.read(persisted) == before + marker)
        #expect(try tool("ntfscat", [m.image.url.path, "/resident.txt"]) == before + marker)
    }

    @Test(arguments: Engine.allCases) func readOnlyResidentMappingNeverConverts(engine: Engine) throws {
        let m = try Mounted(engine, "basic-512")
        var a = try m.lookup("resident.txt"), extent = nb_extent(), count = 0
        #expect(m.api.nb_blockmap!(m.volume, a.ref, 0, a.size, 0, &extent, 1, &count) == ENOTSUP)
        #expect(m.api.nb_query_extents!(m.volume, a.ref, 0, a.size, &extent, 1, &count) == ENOTSUP)
        #expect(m.api.nb_blockmap!(m.volume, a.ref, 0, a.size, 1, &extent, 1, &count) == EROFS)
        try #require(m.api.nb_getattr!(m.volume, a.ref, a.parent_ref, &a) == 0)
        #expect(a.flags & UInt32(NB_RESIDENT) != 0)
        #expect(m.image.io.writeCount == 0)
    }

    @Test(arguments: Engine.allCases) func volumeMetadataOperationsPersist(engine: Engine) throws {
        let m = try Mounted(engine, "basic-512", write: true)
        let getattr = try #require(m.api.nb_getattr)
        let remove = try #require(m.api.nb_remove)
        let statfs = try #require(m.api.nb_statfs)
        let setattr = try #require(m.api.nb_setattr)
        let rename = try #require(m.api.nb_rename)
        let root = m.api.nb_root_ref!(m.volume)
        var stats = nb_stat()
        try #require(statfs(m.volume, &stats) == 0)
        #expect(stats.free_blocks < stats.total_blocks)
        #expect(stats.block_size == 4096)
        var directory = nb_attr(), file = nb_attr()
        let dirname = Array("t7-dir".utf16), old = Array("old".utf16), new = Array("new".utf16)
        try #require(m.api.nb_create!(m.volume, root, dirname, dirname.count, UInt32(NB_DIR), &directory) == 0)
        try #require(m.api.nb_create!(m.volume, directory.ref, old, old.count, UInt32(NB_FILE), &file) == 0)
        #expect(remove(m.volume, root, dirname, dirname.count) == ENOTEMPTY)
        file.size = 1003
        file.mtime = 133_000_000_001_234_500
        try #require(setattr(m.volume, file.ref, &file, UInt32(NB_SET_SIZE | NB_SET_MTIME)) == 0)
        try #require(rename(m.volume, directory.ref, old, old.count, directory.ref, new, new.count) == 0)
        try #require(m.api.nb_unmount!(m.volume) == 0)
        m.volume = nil
        try #require(m.api.nb_mount!(&m.image.dev, 1, &m.volume) == 0)
        let persisted = try m.lookup("t7-dir/new")
        var fetched = nb_attr()
        try #require(getattr(m.volume, persisted.ref, directory.ref, &fetched) == 0)
        #expect(fetched.size == 1003)
        #expect(fetched.mtime == file.mtime)
        #expect(try m.read(fetched) == Data(count: 1003))
        try #require(remove(m.volume, directory.ref, new, new.count) == 0)
        try #require(remove(m.volume, root, dirname, dirname.count) == 0)
        try #require(m.api.nb_unmount!(m.volume) == 0)
        m.volume = nil
        try #require(m.api.nb_mount!(&m.image.dev, 0, &m.volume) == 0)
        #expect(m.api.nb_lookup!(m.volume, root, dirname, dirname.count, &fetched) == ENOENT)
        #expect(statfs(m.volume, &stats) == 0)
        #expect(stats.read_only == 1)
        #expect(remove(m.volume, root, Array("resident.txt".utf16), 12) == EROFS)
        #expect(setattr(m.volume, root, &file, UInt32(NB_SET_MTIME)) == EROFS)
        #expect(rename(m.volume, root, old, old.count, root, new, new.count) == EROFS)
    }

    // Missing filtering loses user files or exposes reserved metadata.
    @Test(arguments: Engine.allCases) func rootListsSystemFilesHidden(engine: Engine) throws {
        let mounted = try Mounted(engine, "basic-512")
        let listing = Listing()
        try #require(mounted.api.nb_readdir!(mounted.volume, mounted.api.nb_root_ref!(mounted.volume), 0, collect, Unmanaged.passUnretained(listing).toOpaque()) == 0)
        let expected = Set(try manifest("basic-512").filter { !$0.path.dropFirst().contains("/") && $0.type != "stream" }.map { String($0.path.dropFirst()) })
        #expect(Set(listing.names) == expected)
        #expect(!listing.names.contains("$MFT"))
    }
    // Wrong geometry, stream selection, Unicode conversion, or runlist breaks bytes.
    @Test(arguments: Engine.allCases) func readMatchesNtfscat(engine: Engine) throws {
        for name in ["basic-512", "4kn", "c64k", "bigdir", "names"] {
            let mounted = try Mounted(engine, name)
            for entry in try manifest(name) where entry.type != "directory" {
                let attr = try mounted.lookup(entry.path)
                #expect(attr.size == UInt64(entry.size))
                let bytes = try mounted.read(attr)
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                #expect(hash == entry.sha256)
                var args = ["-i", String(entry.mft_record)]
                if entry.type == "stream" { args += ["-n", String(entry.path.split(separator: ":").last!)] }
                args.append(mounted.image.url.path)
                #expect(bytes == (try tool("ntfscat", args)))
            }
        }
    }
    // A current-entry cookie replay duplicates the boundary entry of each batch.
    @Test(arguments: Engine.allCases) func readdirResumesFromCookie(engine: Engine) throws {
        let mounted = try Mounted(engine, "bigdir")
        let listing = Listing(limit: 1000)
        var previous: UInt64 = 0
        repeat {
            listing.batch = 0
            try #require(mounted.api.nb_readdir!(mounted.volume, mounted.api.nb_root_ref!(mounted.volume), listing.cookie, collect, Unmanaged.passUnretained(listing).toOpaque()) == 0)
            if listing.batch > 0 { try #require(listing.cookie != previous) }
            previous = listing.cookie
            try #require(listing.names.count <= 100000)
        } while listing.batch == 1000
        #expect(listing.names.count == 100000)
        #expect(Set(listing.names).count == 100000)
        #expect(Set(listing.names) == Set(try manifest("bigdir").map { String($0.path.dropFirst()) }))
    }
    @Test(arguments: Engine.allCases) func cleanStateForMkntfs(engine: Engine) throws {
        let api = try engine.api()
        for name in ["basic-512", "4kn", "c64k", "bigdir", "names"] {
            let image = try Image(name)
            var state = NB_UNSUPPORTED
            try #require(api.nb_probe_state!(&image.dev, &state) == 0)
            #expect(state == NB_CLEAN)
        }
    }
    private func writeFile(_ mounted: Mounted) throws -> (nb_attr, Data) {
        let units = Array("a.bin".utf16)
        var attr = nb_attr()
        try #require(units.withUnsafeBufferPointer { mounted.api.nb_create!(mounted.volume, mounted.api.nb_root_ref!(mounted.volume), $0.baseAddress, $0.count, NB_FILE, &attr) } == 0)
        let bytes = Data((0..<(3 * 1024 * 1024 + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try #require(bytes.withUnsafeBytes { mounted.api.nb_write!(mounted.volume, attr.ref, 0, $0.baseAddress, $0.count) } == 0)
        try #require(mounted.api.nb_sync!(mounted.volume) == 0)
        return (try mounted.lookup("/a.bin"), bytes)
    }
    // Cache-only writes vanish on remount; failure to clear dirty survives ntfsinfo.
    @Test(arguments: Engine.allCases) func writeRoundTrip(engine: Engine) throws {
        let mounted = try Mounted(engine, "basic-512", write: true)
        let (_, expected) = try writeFile(mounted)
        try #require(mounted.api.nb_unmount!(mounted.volume) == 0)
        mounted.volume = nil
        let info = String(decoding: try tool("ntfsinfo", ["-m", mounted.image.url.path]), as: UTF8.self)
        #expect(info.contains("Volume Flags: 0x0000"))
        try #require(mounted.api.nb_mount!(&mounted.image.dev, 0, &mounted.volume) == 0)
        #expect(try mounted.read(mounted.lookup("/a.bin")) == expected)
        #expect(try tool("ntfscat", [mounted.image.url.path, "/a.bin"]) == expected)
    }
    // Mapping must expose physical data, not fabricate contiguous device addresses.
    @Test(arguments: Engine.allCases) func blockmapCoversFile(engine: Engine) throws {
        let mounted = try Mounted(engine, "basic-512", write: true)
        let (attr, expected) = try writeFile(mounted)
        var extents = [nb_extent](repeating: nb_extent(), count: 128)
        var count = 0
        try #require(mounted.api.nb_blockmap!(mounted.volume, attr.ref, 0, attr.alloc_size, 0, &extents, extents.count, &count) == 0)
        let mapped = extents.prefix(count)
        #expect(mapped.reduce(UInt64(0)) { $0 + $1.length } == attr.alloc_size)
        var end: UInt64 = 0
        for extent in mapped {
            #expect(extent.logical == end)
            end += extent.length
            try #require(extent.kind == NB_EXT_DATA)
            let length = min(Int(extent.length), max(0, expected.count - Int(extent.logical)))
            var bytes = Data(count: length)
            try #require(bytes.withUnsafeMutableBytes { pread(mounted.image.fd, $0.baseAddress, length, off_t(extent.physical)) } == length)
            #expect(bytes == expected.subdata(in: Int(extent.logical)..<(Int(extent.logical) + length)))
        }
        try #require(mounted.api.nb_complete_io!(mounted.volume, attr.ref, 0, UInt64(expected.count), 0, 0) == 0)
    }
    @Test(arguments: Engine.allCases) func rawAllocatedWritePersistsExactSize(engine: Engine) throws {
        let mounted = try Mounted(engine, "basic-512", write: true)
        let resident = try mounted.lookup("/resident.txt")
        var extent = nb_extent()
        var count = 0
        #expect(mounted.api.nb_blockmap!(mounted.volume, resident.ref, 0, resident.size, 0, &extent, 1, &count) == 0)
        let name = Array("raw.bin".utf16)
        var attr = nb_attr()
        try #require(name.withUnsafeBufferPointer { mounted.api.nb_create!(mounted.volume, mounted.api.nb_root_ref!(mounted.volume), $0.baseAddress, $0.count, NB_FILE, &attr) } == 0)
        // Convert out of resident form, leaving its data uninitialized.
        try #require(mounted.api.nb_truncate!(mounted.volume, attr.ref, 8192) == 0)
        let expected = Data((0..<1_000_003).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) })
        var extents = [nb_extent](repeating: nb_extent(), count: 128)
        try #require(mounted.api.nb_blockmap!(mounted.volume, attr.ref, 0, UInt64(expected.count), 1, &extents, extents.count, &count) == 0)
        #expect(extents.prefix(count).reduce(UInt64(0)) { $0 + $1.length } == UInt64(expected.count))
        #expect(extents.prefix(count).allSatisfy { $0.kind == NB_EXT_UNINIT })
        try kernelRMWWrite(mounted, ref: attr.ref, offset: 0, payload: expected, extents: extents.prefix(count))
        try #require(mounted.api.nb_complete_io!(mounted.volume, attr.ref, 0, UInt64(expected.count), EIO, 1) == EIO)
        #expect(try mounted.lookup("/raw.bin").size == 8192)
        #expect(try mounted.read(mounted.lookup("/raw.bin")) == Data(count: 8192))
        try #require(mounted.api.nb_complete_io!(mounted.volume, attr.ref, 0, UInt64(expected.count), 0, 1) == 0)
        try #require(mounted.api.nb_unmount!(mounted.volume) == 0)
        mounted.volume = nil
        try #require(mounted.api.nb_mount!(&mounted.image.dev, 0, &mounted.volume) == 0)
        #expect(try mounted.lookup("/raw.bin").size == UInt64(expected.count))
        #expect(try mounted.read(mounted.lookup("/raw.bin")) == expected)
        #expect(try tool("ntfscat", [mounted.image.url.path, "/raw.bin"]) == expected)
    }

    @Test(arguments: Engine.allCases) func rawWriteBeyondValidDataZeroesGap(engine: Engine) throws {
        let mounted = try Mounted(engine, "basic-512", write: true)
        let name = Array("gap.bin".utf16)
        var attr = nb_attr()
        try #require(name.withUnsafeBufferPointer { mounted.api.nb_create!(mounted.volume, mounted.api.nb_root_ref!(mounted.volume), $0.baseAddress, $0.count, NB_FILE, &attr) } == 0)
        try #require(mounted.api.nb_truncate!(mounted.volume, attr.ref, 8192) == 0)
        let offset = 3 * 1024 * 1024 + 5
        let payload = Data(repeating: 0x7b, count: 4097)
        let end = offset + payload.count
        var extents = [nb_extent](repeating: nb_extent(), count: 128)
        var count = 0
        // Simulate a failed earlier offloaded write: allocated but never valid.
        try #require(mounted.api.nb_blockmap!(mounted.volume, attr.ref, 0, UInt64(end), 1, &extents, extents.count, &count) == 0)
        for e in extents.prefix(count) {
            let poison = Data(repeating: 0xcc, count: Int(e.length))
            try #require(poison.withUnsafeBytes { pwrite(mounted.image.fd, $0.baseAddress, $0.count, off_t(e.physical)) } == poison.count)
        }
        try #require(mounted.api.nb_complete_io!(mounted.volume, attr.ref, 0, UInt64(end), EIO, 1) == EIO)
        try #require(mounted.api.nb_blockmap!(mounted.volume, attr.ref, UInt64(offset), UInt64(payload.count), 1, &extents, extents.count, &count) == 0)
        try kernelRMWWrite(mounted, ref: attr.ref, offset: UInt64(offset),
                           payload: payload, extents: extents.prefix(count))
        try #require(mounted.api.nb_complete_io!(mounted.volume, attr.ref, UInt64(offset), UInt64(payload.count), 0, 1) == 0)
        try #require(mounted.api.nb_unmount!(mounted.volume) == 0)
        mounted.volume = nil
        try #require(mounted.api.nb_mount!(&mounted.image.dev, 0, &mounted.volume) == 0)
        let persisted = try mounted.lookup("/gap.bin")
        #expect(persisted.size == UInt64(end))
        var expected = Data(count: offset)
        expected.append(payload)
        #expect(try mounted.read(persisted) == expected)
        #expect(try tool("ntfscat", [mounted.image.url.path, "/gap.bin"]) == expected)
    }

    @Test(arguments: Engine.allCases) func rawWriteCompletionInvalidatesCachedEdges(engine: Engine) throws {
        let mounted = try Mounted(engine, "basic-512", write: true)
        let (attr, _) = try writeFile(mounted)
        var bytes = [UInt8](repeating: 0, count: 17)
        var got = 0
        try #require(mounted.api.nb_read!(mounted.volume, attr.ref, 23, &bytes, 17, &got) == 0)
        var extent = nb_extent()
        var count = 0
        try #require(mounted.api.nb_blockmap!(mounted.volume, attr.ref, 23, 17, 1, &extent, 1, &count) == 0)
        try #require(count == 1)
        let replacement = [UInt8](repeating: 0xa5, count: 17)
        try kernelRMWWrite(mounted, ref: attr.ref, offset: 23, payload: Data(replacement), extents: [extent])
        try #require(mounted.api.nb_complete_io!(mounted.volume, attr.ref, 23, 17, 0, 1) == 0)
        try #require(mounted.api.nb_read!(mounted.volume, attr.ref, 23, &bytes, 17, &got) == 0)
        #expect(bytes == replacement)
        #expect(mounted.api.nb_complete_io!(mounted.volume, attr.ref, 23, 17, EIO, 1) == EIO)
    }

    @Test(arguments: Engine.allCases) func truncatePersistsAndZeroesGrowth(engine: Engine) throws {
        let mounted = try Mounted(engine, "basic-512", write: true)
        let (attr, expected) = try writeFile(mounted)
        try #require(mounted.api.nb_truncate!(mounted.volume, attr.ref, 31) == 0)
        #expect(try mounted.read(mounted.lookup("/a.bin")) == expected.prefix(31))
        try #require(mounted.api.nb_truncate!(mounted.volume, attr.ref, 8193) == 0)
        var wanted = Data(expected.prefix(31))
        wanted.append(Data(count: 8193 - 31))
        #expect(try mounted.read(mounted.lookup("/a.bin")) == wanted)
        try #require(mounted.api.nb_sync!(mounted.volume) == 0)
        try #require(mounted.api.nb_unmount!(mounted.volume) == 0)
        mounted.volume = nil
        try #require(mounted.api.nb_mount!(&mounted.image.dev, 0, &mounted.volume) == 0)
        #expect(try mounted.read(mounted.lookup("/a.bin")) == wanted)
    }
    @Test(arguments: Engine.allCases) func rejectsSignedOffsetOverflow(engine: Engine) throws {
        let mounted = try Mounted(engine, "basic-512", write: true)
        let attr = try mounted.lookup("/resident.txt")
        var byte: UInt8 = 0
        var got = 99
        #expect(mounted.api.nb_read!(mounted.volume, attr.ref, UInt64.max, &byte, 1, &got) == EFBIG)
        #expect(got == 0)
        #expect(mounted.api.nb_write!(mounted.volume, attr.ref, UInt64.max, &byte, 0) == EFBIG)
    }

    @Test(arguments: Engine.allCases) func sparseMutationsAreRejectedWithoutDeviceWrites(engine: Engine) throws {
        let mounted = try Mounted(engine, "basic-512", write: true)
        let name = Array("sparse-policy.bin".utf16)
        var attr = nb_attr()
        try #require(mounted.api.nb_create!(mounted.volume, 5, name, name.count, NB_FILE, &attr) == 0)
        try #require(nb_e2_test_sparse_fixture(mounted.volume, attr.ref, 65536) == 0)
        var marker: UInt8 = 0x7c
        try #require(mounted.api.nb_getattr!(mounted.volume, attr.ref, 5, &attr) == 0)
        try #require(attr.flags & UInt32(NB_SPARSE) != 0)
        try #require(mounted.api.nb_sync!(mounted.volume) == 0)
        let before = mounted.image.io.writeCount
        var extent = nb_extent(), count = 0
        #expect(mounted.api.nb_write!(mounted.volume, attr.ref, 4096, &marker, 1) == EPERM)
        #expect(mounted.api.nb_truncate!(mounted.volume, attr.ref, 1) == EPERM)
        #expect(mounted.api.nb_blockmap!(mounted.volume, attr.ref, 4096, 512, 1, &extent, 1, &count) == EPERM)
        #expect(count == 0)
        #expect(mounted.api.nb_complete_io!(mounted.volume, attr.ref, 4096, 512, 0, 1) == EPERM)
        var request = nb_attr(); request.size = 1
        #expect(mounted.api.nb_setattr!(mounted.volume, attr.ref, &request, UInt32(NB_SET_SIZE)) == EPERM)
        #expect(mounted.image.io.writeCount == before)
        let expected = Data(count: 65536)
        #expect(try mounted.read(attr) == expected)
    }


    @Test(arguments: Engine.allCases) func metadataFaultReadOnlyRejectsRawMutation(engine: Engine) throws {
        let mounted = try Mounted(engine, "bigdir", write: true)
        let (attr, _) = try writeFile(mounted)
        let entry = try #require(manifest("bigdir").last)
        let units = Array(entry.path.dropFirst().utf16)
        var ignored = nb_attr()
        mounted.image.io.failReads = true
        let fault = units.withUnsafeBufferPointer { mounted.api.nb_lookup!(mounted.volume, mounted.api.nb_root_ref!(mounted.volume), $0.baseAddress, $0.count, &ignored) }
        mounted.image.io.failReads = false
        try #require(fault == EIO)
        // The buffered path already observes TT's actual SB_RDONLY flag.
        var byte: UInt8 = 1
        try #require(mounted.api.nb_write!(mounted.volume, attr.ref, 0, &byte, 1) == EROFS)
        let before = mounted.image.io.writeCount
        var extent = nb_extent()
        var count = 0
        #expect(mounted.api.nb_blockmap!(mounted.volume, attr.ref, attr.alloc_size, 4096, 1, &extent, 1, &count) == EROFS)
        #expect(mounted.api.nb_complete_io!(mounted.volume, attr.ref, 0, 4096, 0, 1) == EROFS)
        #expect(mounted.image.io.writeCount == before)
    }
}
