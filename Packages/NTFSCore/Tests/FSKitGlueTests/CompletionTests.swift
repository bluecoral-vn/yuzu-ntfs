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
    device.mappingResource = try mappingResource()
    let (item, extent) = try device.partialVDLFile()
    let payload = [UInt8](repeating: 0xB6, count: 475)
    let mapping = try mapFixture(volume, item, offset: 37, length: 475, id: 0, write: true)
    try kernelRMW(device, volume, item, mapping, offset: 37, bytes: payload)
    device.purges.removeAll()
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
    var types: [FSExtentType] = []
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
    var types: [FSExtentType] { capture(self).types }
    override func packExtent(resource: FSBlockDeviceResource, type: FSExtentType,
                             logicalOffset: off_t, physicalOffset: off_t, length: Int) -> Bool {
        capture(self).types.append(type)
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
                        length: Int, id: Int, write: Bool = false,
                        expectedType: FSExtentType = .data) throws -> ReadMappingPacker {
    let packer = class_createInstance(ReadMappingPacker.self, 0) as! ReadMappingPacker
    var calls = 0, failure: (any Error)?
    volume.blockmapFile(item, offset: offset, length: length, flags: write ? [.write] : [.read],
                        operationID: FSOperationID(rawValue: id), packer: packer) {
        calls += 1; failure = $0
    }
    #expect(calls == 1)
    try #require(failure == nil)
    let sector: off_t = 512
    let start = offset / sector * sector
    let end = (offset + off_t(length) + sector - 1) / sector * sector
    #expect(packer.ranges.reduce(0) { $0 + $1.2 } == Int(end - start))
    var cursor = start
    for (logical, physical, size) in packer.ranges {
        #expect(logical == cursor, "Mapping must cover the whole first sector, with contiguous later runs")
        #expect(logical % sector == 0 && physical % sector == 0 && size % Int(sector) == 0)
        cursor += off_t(size)
    }
    #expect(packer.types.allSatisfy { $0 == expectedType })
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

@Test(arguments: [off_t(0), off_t(4096)])
func readMappingDuringPartialVDLWritePreservesLandedBytes(readOffset: off_t) throws {
    let device = try CompletionDevice(), volume = try device.volume()
    device.mappingResource = try mappingResource()
    let (item, extent) = try device.partialVDLFile() // VDL 37, EOF 8192.
    let mapping = try mapFixture(volume, item, offset: 37, length: 475, id: 41, write: true)
    let payload = [UInt8](repeating: 0xB6, count: 475)
    try kernelRMW(device, volume, item, mapping, offset: 37, bytes: payload)
    let before = device.writes
    _ = try mapFixture(volume, item, offset: readOffset, length: 512, id: 42,
                       expectedType: readOffset == 0 ? .data : .zeroFill)
    #expect(device.writes == before, "A read map must not zero the outstanding write's partial VDL sector")
    #expect(item.operation == FSOperationID(rawValue: 41))
    var raw = [UInt8](repeating: 0, count: 512)
    try #require(pread(device.fd, &raw, raw.count, off_t(extent.physical)) == raw.count)
    #expect(Array(raw.prefix(37)) == [UInt8](repeating: 0x41, count: 37))
    #expect(Array(raw.dropFirst(37)) == payload)
    var calls = 0
    volume.completeIO(for: item, offset: 37, length: 475, status: nil, flags: [.write],
                       operationID: FSOperationID(rawValue: 41)) { error in
        calls += 1; #expect(error == nil)
    }
    #expect(calls == 1)
    volume.unmount {}
    let readOnly = try device.volume(writable: false)
    defer { readOnly.unmount {} }
    var persisted = [UInt8](repeating: 0, count: 512), got = 0
    try #require(nb_engine_e2()!.pointee.nb_read!(device.core, item.ref, 0, &persisted, persisted.count, &got) == 0)
    #expect(got == 512 && persisted == [UInt8](repeating: 0x41, count: 37) + payload)
}

@Test func readOnlyPartialVDLMappingNeverWritesOrPublishesUnsafeSector() throws {
    let device = try CompletionDevice(), volume = try device.volume()
    let (item, extent) = try device.partialVDLFile()
    let poison = [UInt8](repeating: 0xC7, count: 475)
    try #require(pwrite(device.fd, poison, poison.count, off_t(extent.physical + 37)) == poison.count)
    volume.unmount {}
    let readOnly = try device.volume(writable: false)
    defer { readOnly.unmount {} }
    let before = device.writes
    let api = nb_engine_e2()!.pointee
    for offset: UInt64 in [0, 4096] {
        var output = nb_extent(), count = 0
        #expect(api.nb_blockmap!(device.core, item.ref, offset, 512, 0, &output, 1, &count) == ENOTSUP)
        #expect(count == 0)
    }
    #expect(device.writes == before)
    var bytes = [UInt8](repeating: 0, count: 512), got = 0
    try #require(api.nb_read!(device.core, item.ref, 0, &bytes, bytes.count, &got) == 0)
    #expect(got == 512)
    #expect(Array(bytes.prefix(37)) == [UInt8](repeating: 0x41, count: 37))
    #expect(bytes.dropFirst(37).allSatisfy { $0 == 0 })
}

@Test(arguments: [off_t(0), off_t(4096)])
func readMappingWithoutWriteLeasePadsPartialVDLTail(readOffset: off_t) throws {
    let device = try CompletionDevice(), volume = try device.volume()
    defer { volume.unmount {} }
    device.mappingResource = try mappingResource()
    let (item, extent) = try device.partialVDLFile()
    let poison = [UInt8](repeating: 0xC7, count: 475)
    try #require(pwrite(device.fd, poison, poison.count, off_t(extent.physical + 37)) == poison.count)
    #expect(item.operation == nil)
    let before = device.writes
    _ = try mapFixture(volume, item, offset: readOffset, length: 512, id: 51,
                       expectedType: readOffset == 0 ? .data : .zeroFill)
    #expect(device.writes > before)
    var raw = [UInt8](repeating: 1, count: 512)
    try #require(pread(device.fd, &raw, raw.count, off_t(extent.physical)) == raw.count)
    #expect(Array(raw.prefix(37)) == [UInt8](repeating: 0x41, count: 37))
    #expect(raw.dropFirst(37).allSatisfy { $0 == 0 })
    #expect(item.operation == nil)
}

private func fixtureBytes(_ device: CompletionDevice, _ item: YuzuNTFSItem, length: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: length), got = 0
    try #require(nb_engine_e2()!.pointee.nb_read!(device.core, item.ref, 0, &bytes, bytes.count, &got) == 0)
    return Array(bytes.prefix(got))
}

// Model the sector-covering contract observed in the VM. The previous model
// silently subtracted the intra-sector physical offset from an invalid extent,
// thereby repairing precisely the mapping that corrupted real mounted writes.
// Reject byte-granular WRITE extents instead: populate the cache from DATA or
// zeroFill READ mappings, overlay at the file offset, and transfer whole sectors.
private func kernelRMW(_ device: CompletionDevice, _ volume: YuzuNTFSVolume,
                       _ item: YuzuNTFSItem, _ packer: ReadMappingPacker,
                       offset: off_t, bytes: [UInt8]) throws {
    let sector = off_t(device.blockdev.sector_size)
    let start = offset - offset % sector
    let end = ((offset + off_t(bytes.count) + sector - 1) / sector) * sector
    var cursor = start
    for (index, range) in packer.ranges.enumerated() {
        try #require(range.0 == cursor, "WRITE mapping omits the covering sector prefix")
        try #require(packer.types[index] == .data)
        try #require(range.0 % sector == 0 && range.1 % sector == 0 && range.2 % Int(sector) == 0)
        cursor += off_t(range.2)
    }
    try #require(cursor == end, "WRITE mapping must cover the last whole sector")
    var attr = nb_attr()
    try #require(nb_engine_e2()!.pointee.nb_getattr!(device.core, item.ref, item.parent, &attr) == 0)
    let reader = class_createInstance(ReadMappingPacker.self, 0) as! ReadMappingPacker
    var calls = 0, failure: (any Error)?
    volume.blockmapFile(item, offset: start, length: Int(end - start), flags: [.read],
                        operationID: FSOperationID(rawValue: 900), packer: reader) {
        calls += 1; failure = $0
    }
    try #require(calls == 1 && failure == nil)
    var cache = [UInt8](repeating: 0, count: Int(end - start))
    cursor = start
    for (index, range) in reader.ranges.enumerated() {
        let (logical, physical, length) = range
        try #require(logical == cursor, "READ mapping does not start at request")
        cursor += off_t(length)
        if reader.types[index] == .data {
            try cache.withUnsafeMutableBytes {
                try #require(pread(device.fd, $0.baseAddress!.advanced(by: Int(logical - start)),
                                   length, physical) == length)
            }
        } else {
            try #require(reader.types[index] == .zeroFill)
        }
    }
    try #require(cursor == end, "READ mapping exceeds request")
    let eof = min(cache.count, max(0, Int(attr.size) - Int(start)))
    cache.replaceSubrange(eof..<cache.count, with: repeatElement(0, count: cache.count - eof))
    cache.replaceSubrange(Int(offset - start)..<Int(offset - start) + bytes.count, with: bytes)
    for (logical, physical, length) in packer.ranges {
        let cacheOffset = Int(logical - start)
        try cache.withUnsafeBytes {
            try #require(pwrite(device.fd, $0.baseAddress!.advanced(by: cacheOffset),
                                length, physical) == length)
        }
    }
}

@Test(arguments: [false, true])
func residentAppendColdRMWPreservesPrefixAndCompletesObservedRange(readBeforeAppend: Bool) throws {
    let device = try CompletionDevice(), volume = try device.volume()
    defer { volume.unmount {} }
    device.mappingResource = try mappingResource()
    var found: FSItem?
    volume.lookupItem(named: FSFileName(string: "resident.txt"), inDirectory: YuzuNTFSItem(ref: 5, parent: 5)) {
        found = $0; #expect($2 == nil)
    }
    let item = try #require(found as? YuzuNTFSItem)
    let original = try fixtureBytes(device, item, length: 37)
    var attr = nb_attr()
    try #require(nb_engine_e2()!.pointee.nb_getattr!(device.core, item.ref, item.parent, &attr) == 0)
    #expect(attr.flags & UInt32(NB_RESIDENT) != 0)
    // The VM's read map promotes resident.txt before its offset=37,length=9 append.
    if readBeforeAppend { _ = try mapFixture(volume, item, offset: 0, length: 37, id: 5) }
    let mapping = try mapFixture(volume, item, offset: 37, length: 9, id: 6, write: true)
    #expect(mapping.ranges.first?.0 == 0)
    try #require(nb_engine_e2()!.pointee.nb_getattr!(device.core, item.ref, item.parent, &attr) == 0)
    #expect(attr.size == 37, "Mapping must not publish rounded allocation as EOF")
    let promoted = try diskDataAttribute(device, path: "/resident.txt")
    #expect(promoted.allocated == 4096 && promoted.data == 37 && promoted.initialized == 37)
    let physical = try #require(mapping.ranges.first?.1)
    var persistedPrefix = [UInt8](repeating: 0, count: 37)
    try #require(pread(device.fd, &persistedPrefix, 37, physical) == 37)
    #expect(persistedPrefix == original, "Promotion must be durable before the write mapping returns")
    let payload = Array("P0-append".utf8)
    try kernelRMW(device, volume, item, mapping, offset: 37, bytes: payload)
    var calls = 0
    volume.completeIO(for: item, offset: 0, length: 46, status: nil, flags: [.write], operationID: .unspecified) {
        calls += 1; #expect($0 == nil)
    }
    #expect(calls == 1)
    // Unspecified completion cannot release the explicit mapping's lease.
    #expect(item.operation == FSOperationID(rawValue: 6))
    volume.completeIO(for: item, offset: 0, length: 46, status: nil, flags: [.write], operationID: FSOperationID(rawValue: 6)) {
        calls += 1; #expect($0 == nil)
    }
    volume.synchronize(flags: .wait) { calls += 1; #expect($0 == nil) }
    volume.closeItem(item, modes: [.write]) { calls += 1; #expect($0 == nil) }
    #expect(calls == 4 && item.operation == nil)
    volume.unmount {}
    let readOnly = try device.volume(writable: false)
    defer { readOnly.unmount {} }
    #expect(try fixtureBytes(device, item, length: 47) == original + payload)
}

@Test func nonresidentAppendAtNonalignedEOFDoesNotExposeRoundedTail() throws {
    let device = try CompletionDevice()
    let (volume, item) = try mappedFixture(device, writable: true)
    defer { volume.unmount {} }
    let original = try fixtureBytes(device, item, length: 4_194_427)
    let mapping = try mapFixture(volume, item, offset: 4_194_427, length: 9, id: 61, write: true)
    #expect(mapping.ranges.first?.0 == 4_194_304)
    let payload = Array("P0-append".utf8)
    try kernelRMW(device, volume, item, mapping, offset: 4_194_427, bytes: payload)
    var calls = 0
    volume.completeIO(for: item, offset: 0, length: 4_194_436, status: nil, flags: [.write],
                      operationID: FSOperationID(rawValue: 61)) { calls += 1; #expect($0 == nil) }
    #expect(calls == 1 && item.operation == nil)
    volume.unmount {}
    let readOnly = try device.volume(writable: false)
    defer { readOnly.unmount {} }
    #expect(try fixtureBytes(device, item, length: 4_194_437) == original + payload)
}

@Test func millionAndThreeByteColdRMWKeepsExactEOF() throws {
    let device = try CompletionDevice(), volume = try device.volume()
    defer { volume.unmount {} }
    device.mappingResource = try mappingResource()
    var found: FSItem?
    volume.createItem(named: FSFileName(string: "nonaligned.bin"), type: .file,
                      inDirectory: YuzuNTFSItem(ref: 5, parent: 5), attributes: FSItem.SetAttributesRequest()) {
        found = $0; #expect($2 == nil)
    }
    let item = try #require(found as? YuzuNTFSItem)
    let payload = (0..<1_000_003).map { UInt8(truncatingIfNeeded: $0 * 17 + 3) }
    let mapping = try mapFixture(volume, item, offset: 0, length: 1_000_003, id: 71, write: true)
    var attr = nb_attr()
    try #require(nb_engine_e2()!.pointee.nb_getattr!(device.core, item.ref, item.parent, &attr) == 0)
    #expect(attr.size == 0)
    try kernelRMW(device, volume, item, mapping, offset: 0, bytes: payload)
    var calls = 0
    volume.completeIO(for: item, offset: 0, length: 1_000_003, status: nil, flags: [.write],
                      operationID: FSOperationID(rawValue: 71)) { calls += 1; #expect($0 == nil) }
    volume.synchronize(flags: .wait) { calls += 1; #expect($0 == nil) }
    #expect(calls == 2 && item.operation == nil)
    volume.unmount {}
    let readOnly = try device.volume(writable: false)
    defer { readOnly.unmount {} }
    #expect(try fixtureBytes(device, item, length: 1_000_004) == payload)
    try #require(nb_engine_e2()!.pointee.nb_getattr!(device.core, item.ref, item.parent, &attr) == 0)
    #expect(attr.size == 1_000_003)
}

// ntfsinfo reads the detached backing file, not E2's inode/page caches.
private func diskDataAttribute(_ device: CompletionDevice, path: String) throws
    -> (allocated: Int, data: Int, initialized: Int) {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process(), output = Pipe()
    process.executableURL = root.appendingPathComponent("tools/bin/ntfsinfo")
    process.arguments = ["-f", "-F", path, device.image.path]
    process.standardOutput = output
    try process.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    let attribute = try #require(text.components(separatedBy: "Dumping attribute $DATA").last)
    func field(_ name: String) throws -> Substring {
        let line = try #require(attribute.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(name + ":") })
        return try #require(line.split(separator: ":").last?.split(whereSeparator: { $0.isWhitespace }).first)
    }
    try #require(try field("Resident") == "No")
    return (try #require(Int(field("Allocated size"))),
            try #require(Int(field("Data size"))),
            try #require(Int(field("Initialized size"))))
}

@Test func sdkPackerSerializesByteCoordinatesWithoutValidatingKernelContract() throws {
    // Serializer acceptance is not a valid device-I/O contract. The VM
    // corrupted this tuple; production must publish covering whole sectors.
    let selector = NSSelectorFromString("initWithBlockmapFlags:")
    let method = try #require(class_getInstanceMethod(FSExtentPacker.self, selector))
    typealias Initialize = @convention(c) (AnyObject, Selector, UInt) -> AnyObject
    let initialize = unsafeBitCast(method_getImplementation(method), to: Initialize.self)
    let packer = initialize(class_createInstance(FSExtentPacker.self, 0)! as AnyObject,
                            selector, FSBlockmapFlags.write.rawValue) as! FSExtentPacker
    #expect(packer.packExtent(resource: try mappingResource(), type: .data,
                             logicalOffset: 37, physicalOffset: 53_121_061, length: 9))
    let data = try #require(packer.perform(NSSelectorFromString("extentDataByExtentsPacked"))?.takeUnretainedValue() as? Data)
    try #require(data.count == 24, "SDK extent serialization layout changed")
    #expect(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) } == 9)
    #expect(data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) } == 53_121_061)
    #expect(data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self)) } == 37)
}

private func createRMWFixture(_ device: CompletionDevice, _ volume: YuzuNTFSVolume) throws -> YuzuNTFSItem {
    device.mappingResource = try mappingResource()
    var found: FSItem?
    volume.createItem(named: FSFileName(string: "rmw.bin"), type: .file,
                      inDirectory: YuzuNTFSItem(ref: 5, parent: 5), attributes: FSItem.SetAttributesRequest()) {
        found = $0; #expect($2 == nil)
    }
    return try #require(found as? YuzuNTFSItem)
}

private func writePrefixAndGrow(_ device: CompletionDevice, _ volume: YuzuNTFSVolume,
                                _ item: YuzuNTFSItem) throws {
    let mapping = try mapFixture(volume, item, offset: 0, length: 37, id: 81, write: true)
    try kernelRMW(device, volume, item, mapping, offset: 0, bytes: [UInt8](repeating: 0x41, count: 37))
    var calls = 0
    volume.completeIO(for: item, offset: 0, length: 37, status: nil, flags: [.write],
                      operationID: FSOperationID(rawValue: 81)) { calls += 1; #expect($0 == nil) }
    let growth = FSItem.SetAttributesRequest(); growth.size = 8192
    volume.setAttributes(growth, on: item) { attributes, error in
        calls += 1; #expect(error == nil && attributes?.size == 8192)
    }
    volume.synchronize(flags: .wait) { calls += 1; #expect($0 == nil) }
    #expect(calls == 3)
    let sizes = try diskDataAttribute(device, path: "/rmw.bin")
    #expect(sizes.data == 8192 && sizes.initialized == 37)
}

@Test func thirtySevenByteColdRMWThenFtruncatePreservesPrefixAndZeroTail() throws {
    let device = try CompletionDevice(), volume = try device.volume()
    defer { volume.unmount {} }
    let item = try createRMWFixture(device, volume)
    try writePrefixAndGrow(device, volume, item)
    let expected = [UInt8](repeating: 0x41, count: 37) + [UInt8](repeating: 0, count: 8192 - 37)
    #expect(try fixtureBytes(device, item, length: 8193) == expected)
    volume.unmount {}
    let readOnly = try device.volume(writable: false)
    defer { readOnly.unmount {} }
    #expect(try fixtureBytes(device, item, length: 8193) == expected)
}

@Test(arguments: [off_t(211), off_t(6191)])
func gapWriteColdRMWNeverZerosInitializedPrefix(offset: off_t) throws {
    let device = try CompletionDevice(), volume = try device.volume()
    defer { volume.unmount {} }
    let item = try createRMWFixture(device, volume)
    try writePrefixAndGrow(device, volume, item)
    let payload = [UInt8](repeating: 0xB6, count: 659)
    let mapping = try mapFixture(volume, item, offset: offset, length: payload.count, id: 82, write: true)
    try kernelRMW(device, volume, item, mapping, offset: offset, bytes: payload)
    var calls = 0
    volume.completeIO(for: item, offset: offset, length: payload.count, status: nil, flags: [.write],
                      operationID: FSOperationID(rawValue: 82)) { calls += 1; #expect($0 == nil) }
    #expect(calls == 1)
    var expected = [UInt8](repeating: 0, count: 8192)
    expected.replaceSubrange(0..<37, with: repeatElement(0x41, count: 37))
    expected.replaceSubrange(Int(offset)..<Int(offset) + payload.count, with: payload)
    volume.unmount {}
    let readOnly = try device.volume(writable: false)
    defer { readOnly.unmount {} }
    #expect(try fixtureBytes(device, item, length: 8193) == expected)
    let sizes = try diskDataAttribute(device, path: "/rmw.bin")
    #expect(sizes.data == 8192 && sizes.initialized == Int(offset) + payload.count)
}

@Test func appendWriteMappingCoversWholeDeviceSector() throws {
    let device = try CompletionDevice(), volume = try device.volume()
    defer { volume.unmount {} }
    device.mappingResource = try mappingResource()
    var found: FSItem?
    volume.lookupItem(named: FSFileName(string: "resident.txt"), inDirectory: YuzuNTFSItem(ref: 5, parent: 5)) {
        found = $0; #expect($2 == nil)
    }
    let packer = class_createInstance(ReadMappingPacker.self, 0) as! ReadMappingPacker
    var failure: (any Error)?
    volume.blockmapFile(try #require(found), offset: 37, length: 9, flags: [.write],
                       operationID: FSOperationID(rawValue: 6), packer: packer) { failure = $0 }
    try #require(failure == nil)
    #expect(packer.ranges.first?.0 == 0)
    #expect((try #require(packer.ranges.first?.1)) % 512 == 0)
    #expect(packer.ranges.reduce(0) { $0 + $1.2 } == 512)
}

@Test func residentReadMapCanBackAppendWithoutWriteBlockmap() throws {
    let device = try CompletionDevice(), volume = try device.volume()
    defer { volume.unmount {} }
    device.mappingResource = try mappingResource()
    var found: FSItem?
    volume.lookupItem(named: FSFileName(string: "resident.txt"), inDirectory: YuzuNTFSItem(ref: 5, parent: 5)) {
        found = $0; #expect($2 == nil)
    }
    let item = try #require(found as? YuzuNTFSItem)
    let original = try fixtureBytes(device, item, length: 37)
    let cached = try mapFixture(volume, item, offset: 0, length: 37, id: 5)
    #expect(item.inhibitsKernelIO == false && item.operation == nil)
    // Observed fixed VM callback sequence: READ(0,37) returns DATA(0,512),
    // then successful completeIO(0,46,unspecified), without a WRITE blockmap.
    try kernelRMW(device, volume, item, cached, offset: 37, bytes: Array("P0-append".utf8))
    volume.completeIO(for: item, offset: 0, length: 46, status: nil, flags: [.write],
                       operationID: .unspecified) { #expect($0 == nil) }
    volume.unmount {}
    let readOnly = try device.volume(writable: false)
    defer { readOnly.unmount {} }
    #expect(try fixtureBytes(device, item, length: 47) == original + Array("P0-append".utf8))
}
