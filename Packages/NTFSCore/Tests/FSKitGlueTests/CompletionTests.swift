// SPDX-License-Identifier: GPL-2.0-only
import Darwin
import Foundation
import FSKit
import ObjectiveC
import Testing
import EngineE2
import NTFSBridge
import NTFSProbe
@testable import FSKitGlue

private final class CompletionDevice: YuzuNTFSDeviceAccess {
    let image: URL
    let fd: Int32
    let size: UInt64
    let boot: NTFSBootSector
    var core: OpaquePointer?
    var writes = 0
    var purges: [[nb_extent]] = []
    var metadataActive = false
    var extentResource: FSBlockDeviceResource? { nil }
    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        image = FileManager.default.temporaryDirectory.appendingPathComponent("yuzu-completion-\(UUID()).img")
        try FileManager.default.copyItem(at: root.appendingPathComponent("fixtures/basic-512.img"), to: image)
        fd = open(image.path, O_RDWR)
        try #require(fd >= 0)
        var stat = Darwin.stat(); try #require(fstat(fd, &stat) == 0)
        size = UInt64(stat.st_size)
        var sector = [UInt8](repeating: 0, count: 512)
        try #require(pread(fd, &sector, sector.count, 0) == sector.count)
        boot = try sector.withUnsafeBytes { try NTFSBootSector.parse($0) }
    }
    deinit { close(fd); try? FileManager.default.removeItem(at: image) }
    var blockdev: nb_blockdev {
        nb_blockdev(ctx: Unmanaged.passUnretained(self).toOpaque(), size: size, sector_size: 512,
            read: { ctx, off, buf, len in
                let device = Unmanaged<CompletionDevice>.fromOpaque(ctx!).takeUnretainedValue()
                var done = 0
                while done < len {
                    let n = pread(device.fd, buf!.advanced(by: done), len - done, off_t(off) + off_t(done))
                    if n < 0 { if errno == EINTR { continue }; return errno }
                    if n == 0 { return EIO }; done += n
                }
                return 0
            }, write: { ctx, off, buf, len in
                let device = Unmanaged<CompletionDevice>.fromOpaque(ctx!).takeUnretainedValue()
                device.writes += 1
                var done = 0
                while done < len {
                    let n = pwrite(device.fd, buf!.advanced(by: done), len - done, off_t(off) + off_t(done))
                    if n < 0 { if errno == EINTR { continue }; return errno }
                    if n == 0 { return EIO }; done += n
                }
                return 0
            }, flush: { ctx in
                let device = Unmanaged<CompletionDevice>.fromOpaque(ctx!).takeUnretainedValue()
                return fsync(device.fd) == 0 ? 0 : errno
            })
    }
    func purge<Extents: Collection>(_ extents: Extents) throws where Extents.Element == nb_extent {
        purges.append(Array(extents))
    }
    func volume() throws -> YuzuNTFSVolume {
        var api = nb_engine_e2()!.pointee
        api.nb_mount = { dev, rw, out in
            let device = Unmanaged<CompletionDevice>.fromOpaque(dev!.pointee.ctx!).takeUnretainedValue()
            let result = nb_engine_e2()!.pointee.nb_mount!(dev, rw, out)
            device.core = out!.pointee
            return result
        }
        let volume = YuzuNTFSVolume(device: self, boot: boot, writable: true, api: api)
        var error: (any Error)?
        volume.activate(options: class_createInstance(FSTaskOptions.self, 0) as! FSTaskOptions) { _, failure in error = failure }
        try #require(error == nil)
        return volume
    }
    func partialVDLFile() throws -> (YuzuNTFSItem, nb_extent) {
        let api = nb_engine_e2()!.pointee
        let name = Array("completion.bin".utf16), root = api.nb_root_ref!(core)
        var attr = nb_attr(), extent = nb_extent(), count = 0
        try #require(api.nb_create!(core, root, name, name.count, NB_FILE, &attr) == 0)
        let prefix = [UInt8](repeating: 0x41, count: 37)
        try #require(api.nb_write!(core, attr.ref, 0, prefix, prefix.count) == 0)
        try #require(api.nb_truncate!(core, attr.ref, 8192) == 0)
        try #require(api.nb_blockmap!(core, attr.ref, 0, 512, 1, &extent, 1, &count) == 0)
        return (YuzuNTFSItem(ref: attr.ref, parent: root), extent)
    }
}

@Test func untrackedWriteCompletionPreservesLandedPartialVDLBlock() throws {
    let device = try CompletionDevice(), volume = try device.volume()
    defer { volume.unmount {} }
    let (item, extent) = try device.partialVDLFile()
    let payload = [UInt8](repeating: 0xB6, count: 475)
    try #require(pwrite(device.fd, payload, payload.count, off_t(extent.physical + 37)) == payload.count)
    var calls = 0, failure: (any Error)?
    volume.completeIO(for: item, offset: 37, length: 475, status: nil, flags: [.write], operationID: .unspecified) {
        calls += 1; failure = $0
    }
    #expect(calls == 1 && failure == nil)
    var bytes = [UInt8](repeating: 0, count: 512)
    try #require(pread(device.fd, &bytes, bytes.count, off_t(extent.physical)) == bytes.count)
    #expect(Array(bytes.prefix(37)) == [UInt8](repeating: 0x41, count: 37))
    #expect(Array(bytes.dropFirst(37)) == payload)
    #expect(device.purges.count == 2)
    for purge in device.purges {
        #expect(purge.count == 1)
        #expect(purge.first?.physical == extent.physical + 37)
        #expect(purge.first?.length == 475)
        #expect(purge.first?.kind == NB_EXT_DATA)
    }
}

@Test func untrackedReadCompletionAfterHookPerformsNoDeviceWrites() throws {
    let device = try CompletionDevice(), volume = try device.volume()
    let hook = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    volume.forceReadOnlyURL = hook
    defer { try? FileManager.default.removeItem(at: hook); volume.unmount {} }
    let (item, _) = try device.partialVDLFile()
    let api = nb_engine_e2()!.pointee
    var extents = [nb_extent](repeating: nb_extent(), count: 8), count = 0
    try #require(api.nb_blockmap!(device.core, item.ref, 0, 8192, 0, &extents, extents.count, &count) == 0)
    try Data().write(to: hook)
    let before = device.writes
    var calls = 0, failure: (any Error)?
    volume.completeIO(for: item, offset: 0, length: 8192, status: nil, flags: [], operationID: .unspecified) {
        calls += 1; failure = $0
    }
    #expect(calls == 1 && failure == nil)
    #expect(device.writes == before)
    #expect(device.purges.count == 2)
}
