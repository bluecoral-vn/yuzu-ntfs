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
    var extentResource: FSBlockDeviceResource? { mappingResource }
    var mappingResource: FSBlockDeviceResource?
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
    func volume(writable: Bool = true) throws -> YuzuNTFSVolume {
        var api = nb_engine_e2()!.pointee
        api.nb_mount = { dev, rw, out in
            let device = Unmanaged<CompletionDevice>.fromOpaque(dev!.pointee.ctx!).takeUnretainedValue()
            let result = nb_engine_e2()!.pointee.nb_mount!(dev, rw, out)
            device.core = out!.pointee
            return result
        }
        let volume = YuzuNTFSVolume(device: self, boot: boot, writable: writable, api: api)
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

// The SDK constructs these objects only inside a mounted callback. Supply the
// resource/packer/buffer boundary in-process while exercising the real volume,
// real bridge and real disposable fixture. The resource never owns an OS fd.
private final class MappingCapture {
    var ranges: [(off_t, off_t, Int)] = []
    let storage = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 8)
    deinit { storage.deallocate() }
}
// Only the stable address is used, never read/written as shared mutable state.
nonisolated(unsafe) private var mappingCaptureKey: UInt8 = 0
private func capture(_ object: NSObject) -> MappingCapture {
    if let capture = objc_getAssociatedObject(object, &mappingCaptureKey) as? MappingCapture { return capture }
    let capture = MappingCapture()
    objc_setAssociatedObject(object, &mappingCaptureKey, capture, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return capture
}
private final class ReadMappingPacker: FSExtentPacker {
    var ranges: [(off_t, off_t, Int)] { capture(self).ranges }
    override func packExtent(resource: FSBlockDeviceResource, type: FSExtentType,
                             logicalOffset: off_t, physicalOffset: off_t, length: Int) -> Bool {
        #expect(type == .data)
        capture(self).ranges.append((logicalOffset, physicalOffset, length))
        return true
    }
}
private final class ReadMappingBuffer: FSMutableFileDataBuffer {
    var storage: UnsafeMutableRawPointer { capture(self).storage }
    override var length: Int { 512 }
    // Swift marks mutableBytes unavailable even to overrides. Install the
    // test-only ObjC implementation once; the production overlay calls it.
    static let installStorage: Void = {
        let bytes: @convention(block) (ReadMappingBuffer) -> UnsafeMutableRawPointer = { $0.storage }
        precondition(class_addMethod(ReadMappingBuffer.self, NSSelectorFromString("mutableBytes"),
                                     imp_implementationWithBlock(bytes), "^v@:"))
    }()
    static func make() -> ReadMappingBuffer {
        _ = installStorage
        return class_createInstance(ReadMappingBuffer.self, 0) as! ReadMappingBuffer
    }
}
private func mappingResource() throws -> FSBlockDeviceResource {
    let descriptor = try #require(class_getInstanceVariable(FSBlockDeviceResource.self, "_fileDescriptor"))
    let encoding = try #require(ivar_getTypeEncoding(descriptor))
    try #require(String(cString: encoding) == "i", "SDK resource descriptor layout changed")
    let resource = class_createInstance(FSBlockDeviceResource.self, 0) as! FSBlockDeviceResource
    Unmanaged.passUnretained(resource).toOpaque().advanced(by: ivar_getOffset(descriptor))
        .storeBytes(of: Int32(-1), as: Int32.self)
    return resource
}
private func mappedFixture(_ device: CompletionDevice, writable: Bool) throws -> (YuzuNTFSVolume, YuzuNTFSItem) {
    device.mappingResource = try mappingResource()
    let volume = try device.volume(writable: writable)
    var found: FSItem?
    let directory = YuzuNTFSItem(ref: nb_engine_e2()!.pointee.nb_root_ref!(device.core), parent: 5)
    volume.lookupItem(named: FSFileName(string: "nonresident.bin"), inDirectory: directory) {
        found = $0; #expect($2 == nil)
    }
    return (volume, try #require(found as? YuzuNTFSItem))
}
private func mapFixture(_ volume: YuzuNTFSVolume, _ item: YuzuNTFSItem, offset: off_t,
                        length: Int, id: Int, write: Bool = false) throws -> ReadMappingPacker {
    let packer = class_createInstance(ReadMappingPacker.self, 0) as! ReadMappingPacker
    var calls = 0, failure: (any Error)?
    volume.blockmapFile(item, offset: offset, length: length, flags: write ? [.write] : [.read],
                        operationID: FSOperationID(rawValue: id), packer: packer) {
        calls += 1; failure = $0
    }
    #expect(calls == 1)
    try #require(failure == nil)
    #expect(packer.ranges.reduce(0) { $0 + $1.2 } == length)
    return packer
}

@Test(arguments: [false, true])
func readMappingsWithoutCompletionAllowLaterReadAndMapping(writable: Bool) throws {
    let device = try CompletionDevice()
    let (volume, item) = try mappedFixture(device, writable: writable)
    defer { volume.unmount {} }
    let first = try mapFixture(volume, item, offset: 0, length: 1_048_576, id: 11)
    _ = try mapFixture(volume, item, offset: 1_048_576, length: 1_048_576, id: 12)
    // Deliberately no completeIO: the observed host read maps had none.
    let buffer = ReadMappingBuffer.make()
    var calls = 0, got = 0, failure: (any Error)?
    volume.read(from: item, at: 0, length: 512, into: buffer) {
        calls += 1; got = $0; failure = $1
    }
    #expect(calls == 1 && failure == nil && got == 512)
    var expected = Data(count: 512)
    let physical = try #require(first.ranges.first?.1)
    try #require(expected.withUnsafeMutableBytes { pread(device.fd, $0.baseAddress, 512, physical) } == 512)
    #expect(Data(bytes: buffer.storage, count: 512) == expected)
    _ = try mapFixture(volume, item, offset: 2_097_152, length: 512, id: 13)
    #expect(item.operation == nil && item.extents.isEmpty)
    if !writable { #expect(device.writes == 0) }
}

@Test func readMappingWithoutCompletionAllowsShrinkAndPinnedUnlink() throws {
    let device = try CompletionDevice()
    let (volume, item) = try mappedFixture(device, writable: true)
    defer { volume.unmount {} }
    _ = try mapFixture(volume, item, offset: 1_048_576, length: 1_048_576, id: 21)
    let shrink = FSItem.SetAttributesRequest(); shrink.size = 4096
    var calls = 0
    volume.setAttributes(shrink, on: item) { attributes, error in
        calls += 1; #expect(error == nil && attributes?.size == 4096)
    }
    #expect(calls == 1)
    let before = try mapFixture(volume, item, offset: 0, length: 512, id: 22)
    volume.removeItem(item, named: FSFileName(string: "nonresident.bin"),
                      fromDirectory: YuzuNTFSItem(ref: 5, parent: 5)) {
        calls += 1; #expect($0 == nil)
    }
    #expect(calls == 2 && item.releasePin != nil)
    let after = try mapFixture(volume, item, offset: 0, length: 512, id: 23)
    #expect(before.ranges.first?.1 == after.ranges.first?.1)
    var attr = nb_attr()
    #expect(nb_engine_e2()!.pointee.nb_getattr!(device.core, item.ref, item.parent, &attr) == 0)
    #expect(attr.size == 4096 && attr.nlink == 0)
}

@Test func readMappingsDoNotOwnOrReleaseWriteShrinkLease() throws {
    let device = try CompletionDevice()
    let (volume, item) = try mappedFixture(device, writable: true)
    defer { volume.unmount {} }
    _ = try mapFixture(volume, item, offset: 4096, length: 512, id: 31, write: true)
    _ = try mapFixture(volume, item, offset: 8192, length: 512, id: 32)
    #expect(item.operation == FSOperationID(rawValue: 31))
    #expect(item.extents.count == 1 && item.extents.first?.logical == 4096)
    let shrink = FSItem.SetAttributesRequest(); shrink.size = 4096
    var calls = 0
    volume.setAttributes(shrink, on: item) { _, error in
        calls += 1; #expect((error as NSError?)?.code == Int(EBUSY))
    }
    volume.completeIO(for: item, offset: 8192, length: 512, status: nil, flags: [.read],
                       operationID: FSOperationID(rawValue: 32)) { error in
        calls += 1; #expect(error == nil)
    }
    #expect(item.operation == FSOperationID(rawValue: 31))
    volume.completeIO(for: item, offset: 4096, length: 512, status: nil, flags: [.write],
                       operationID: FSOperationID(rawValue: 31)) { error in
        calls += 1; #expect(error == nil)
    }
    volume.setAttributes(shrink, on: item) { attributes, error in
        calls += 1; #expect(error == nil && attributes?.size == 4096)
    }
    #expect(calls == 4 && item.operation == nil)
}
