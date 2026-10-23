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
private final class Image {
    let fd: Int32
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
        var stat = Darwin.stat()
        try #require(fstat(fd, &stat) == 0)
        dev = nb_blockdev(ctx: UnsafeMutableRawPointer(bitPattern: Int(fd) + 1), size: UInt64(stat.st_size), sector_size: name == "4kn" ? 4096 : 512, read: { ctx, off, buf, len in
            let fd = Int32(Int(bitPattern: ctx) - 1)
            var done = 0
            while done < len {
                let n = pread(fd, buf!.advanced(by: done), len - done, off_t(off) + off_t(done))
                if n < 0 { if errno == EINTR { continue }; return errno }
                if n == 0 { return EIO }
                done += n
            }
            return 0
        }, write: { ctx, off, buf, len in
            let fd = Int32(Int(bitPattern: ctx) - 1)
            var done = 0
            while done < len {
                let n = pwrite(fd, buf!.advanced(by: done), len - done, off_t(off) + off_t(done))
                if n < 0 { if errno == EINTR { continue }; return errno }
                if n == 0 { return EIO }
                done += n
            }
            return 0
        }, flush: { ctx in fsync(Int32(Int(bitPattern: ctx) - 1)) == 0 ? 0 : errno })
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
        #expect(mounted.api.nb_blockmap!(mounted.volume, resident.ref, 0, resident.size, 0, &extent, 1, &count) == ENOTSUP)
        let name = Array("raw.bin".utf16)
        var attr = nb_attr()
        try #require(name.withUnsafeBufferPointer { mounted.api.nb_create!(mounted.volume, mounted.api.nb_root_ref!(mounted.volume), $0.baseAddress, $0.count, NB_FILE, &attr) } == 0)
        // Convert out of resident form, leaving its data uninitialized.
        try #require(mounted.api.nb_truncate!(mounted.volume, attr.ref, 8192) == 0)
        let expected = Data((0..<1_000_003).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) })
        var extents = [nb_extent](repeating: nb_extent(), count: 128)
        try #require(mounted.api.nb_blockmap!(mounted.volume, attr.ref, 0, UInt64(expected.count), 1, &extents, extents.count, &count) == 0)
        #expect(extents.prefix(count).reduce(UInt64(0)) { $0 + $1.length } == UInt64(expected.count))
        for e in extents.prefix(count) {
            try #require(e.kind == NB_EXT_UNINIT)
            let bytes = expected.subdata(in: Int(e.logical)..<Int(e.logical + e.length))
            try #require(bytes.withUnsafeBytes { pwrite(mounted.image.fd, $0.baseAddress, $0.count, off_t(e.physical)) } == bytes.count)
        }
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
        for e in extents.prefix(count) {
            let bytes = payload.subdata(in: Int(e.logical) - offset..<Int(e.logical + e.length) - offset)
            try #require(bytes.withUnsafeBytes { pwrite(mounted.image.fd, $0.baseAddress, $0.count, off_t(e.physical)) } == bytes.count)
        }
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
        try #require(replacement.withUnsafeBytes { pwrite(mounted.image.fd, $0.baseAddress, 17, off_t(extent.physical)) } == 17)
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
}
