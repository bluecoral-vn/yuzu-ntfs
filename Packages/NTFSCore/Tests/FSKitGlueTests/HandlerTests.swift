// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import ObjectiveC
import Testing
import FSKit
import NTFSProbe
import NTFSBridge
@testable import FSKitGlue

private final class HandlerDevice: YuzuNTFSDeviceAccess {
    let state: HandlerCore
    init(_ state: HandlerCore) { self.state = state }
    var extentResource: FSBlockDeviceResource? { nil }
    var metadataActive = false
    var blockdev: nb_blockdev { nb_blockdev(ctx: Unmanaged.passUnretained(state).toOpaque(), size: 1 << 20, sector_size: 512, read: nil, write: nil, flush: nil) }
    func purge<Extents: Collection>(_ extents: Extents) throws where Extents.Element == nb_extent {}
}
private final class HandlerCore {
    var readOnly = false
    var failure: Int32 = 0
    var size: UInt64 = 8192
    var flags: UInt32 = UInt32(NB_RESIDENT)
    var mounts = 0
    var closes = 0
    var removes = 0
    var created = false
    var failHold = false
    var failSetattr = false
    var completedStatus: Int32?
    var mappingPhysical: UInt64?
    var directoryCookie: UInt64?
    static func state(_ pointer: OpaquePointer?) -> HandlerCore { Unmanaged<HandlerCore>.fromOpaque(UnsafeRawPointer(pointer!)).takeUnretainedValue() }
    var api: nb_engine {
        var api = nb_engine()
        api.nb_mount = { dev, _, out in
            let state = Unmanaged<HandlerCore>.fromOpaque(dev!.pointee.ctx!).takeUnretainedValue()
            if state.failure != 0 { return state.failure }
            state.mounts += 1; out!.pointee = OpaquePointer(dev!.pointee.ctx); return 0
        }
        api.nb_root_ref = { _ in 5 }
        api.nb_hold = { core, _ in let s = HandlerCore.state(core); return s.failHold ? ENOMEM : s.failure }
        api.nb_release = { _, _ in 0 }
        api.nb_sync = { core in HandlerCore.state(core).failure }
        api.nb_unmount = { core in HandlerCore.state(core).closes += 1; return 0 }
        api.nb_dispose = { core in HandlerCore.state(core).closes += 1; return 0 }
        api.nb_query_extents = { core, _, offset, length, buffer, capacity, count in
            let s = HandlerCore.state(core)
            if s.failure != 0 { return s.failure }
            guard let physical = s.mappingPhysical, capacity > 0 else { return ENOTSUP }
            buffer!.pointee = nb_extent(logical: offset, physical: physical, length: length, kind: UInt32(NB_EXT_DATA))
            count!.pointee = 1
            return 0
        }
        api.nb_read_map_during_write = api.nb_query_extents
        api.nb_statfs = { core, out in let s = HandlerCore.state(core); out!.pointee.read_only = s.readOnly ? 1 : 0; return s.failure }
        api.nb_getattr = { core, ref, parent, out in
            let s = HandlerCore.state(core); if s.failure != 0 { return s.failure }
            out!.pointee = nb_attr(); out!.pointee.ref = ref; out!.pointee.parent_ref = parent
            out!.pointee.size = ref == 5 ? 0 : s.size
            out!.pointee.type = ref == 5 ? NB_DIR : NB_FILE; out!.pointee.flags = s.flags; return 0
        }
        api.nb_lookup = { core, _, _, _, out in let s = HandlerCore.state(core); out!.pointee.ref = 42; out!.pointee.parent_ref = 5; return s.failure }
        api.nb_create = { core, _, _, _, _, out in let s = HandlerCore.state(core); if s.failure != 0 { return s.failure }; s.created = true; out!.pointee.ref = 42; out!.pointee.parent_ref = 5; return 0 }
        api.nb_setattr = { core, _, attr, valid in
            let s = HandlerCore.state(core)
            if s.failSetattr { return ENOSPC }; if s.failure != 0 { return s.failure }
            if valid & UInt32(NB_SET_SIZE) != 0 { s.size = attr!.pointee.size }
            return 0
        }
        api.nb_remove = { core, _, _, _ in let s = HandlerCore.state(core); s.removes += 1; s.created = false; return s.failure }
        api.nb_rename = { core, _, _, _, _, _, _ in HandlerCore.state(core).failure }
        api.nb_read = { core, _, _, _, _, got in got!.pointee = 0; return HandlerCore.state(core).failure }
        api.nb_write = { core, _, _, _, _ in HandlerCore.state(core).failure }
        api.nb_complete_io = { core, _, _, _, status, _ in let s = HandlerCore.state(core); s.completedStatus = status; return s.failure }
        api.nb_blockmap = { core, _, offset, length, _, buffer, capacity, count in
            let s = HandlerCore.state(core)
            if s.failure != 0 { return s.failure }
            guard let physical = s.mappingPhysical, capacity > 0 else { return ENOTSUP }
            buffer!.pointee = nb_extent(logical: offset, physical: physical, length: length, kind: UInt32(NB_EXT_DATA))
            count!.pointee = 1
            return 0
        }
        api.nb_readdir = { core, _, _, callback, context in
            let s = HandlerCore.state(core)
            if s.failure != 0 { return s.failure }
            if let cookie = s.directoryCookie {
                var name: UInt16 = 120
                var attr = nb_attr(); attr.ref = 42; attr.parent_ref = 5; attr.type = NB_FILE
                _ = callback!(context, &name, 1, &attr, cookie)
            }
            return 0
        }
        return api
    }
    func volume() throws -> YuzuNTFSVolume {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let boot = try Data(contentsOf: repo.appendingPathComponent("fixtures/basic-512.img"), options: .mappedIfSafe).prefix(512).withUnsafeBytes { try NTFSBootSector.parse($0) }
        return YuzuNTFSVolume(device: HandlerDevice(self), boot: boot, writable: true, api: api)
    }
}
private final class ReplyOnce {
    var calls = 0
    var error: (any Error)?
    func accept(_ error: (any Error)?) { calls += 1; self.error = error }
    func assertOnce() { #expect(calls == 1) }
}

@Test func effectiveReadOnlyRejectsWriteOpenAndInhibitsResidentPublication() throws {
    let core = HandlerCore(), volume = try core.volume()
    var root: FSItem?
    // SDK has no public options initializer; this handler never reads options.
    volume.activate(options: class_createInstance(FSTaskOptions.self, 0) as! FSTaskOptions) { root = $0; #expect($1 == nil) }
    try #require(root != nil)
    core.readOnly = true
    let reply = ReplyOnce()
    let item = YuzuNTFSItem(ref: 42, parent: 5)
    volume.openItem(item, modes: [.write], replyHandler: reply.accept)
    reply.assertOnce(); #expect((reply.error as NSError?)?.code == Int(EROFS))
    let attributesReply = ReplyOnce()
    volume.getAttributes(FSItem.GetAttributesRequest(), of: item) { attributes, error in
        attributesReply.accept(error); #expect(attributes?.inhibitKernelOffloadedIO == true)
    }
    attributesReply.assertOnce()
}

@Test func publishedResidentKeepsEligibilityAfterReadOnlyLatch() throws {
    let core = HandlerCore(), volume = try core.volume()
    var root: FSItem?, published: FSItem?
    volume.activate(options: class_createInstance(FSTaskOptions.self, 0) as! FSTaskOptions) { root = $0; #expect($1 == nil) }
    volume.lookupItem(named: FSFileName(string: "resident.txt"), inDirectory: try #require(root)) { published = $0; #expect($2 == nil) }
    let item = try #require(published)
    volume.getAttributes(FSItem.GetAttributesRequest(), of: item) { attributes, error in
        #expect(error == nil); #expect(attributes?.inhibitKernelOffloadedIO == false)
    }
    core.readOnly = true
    volume.getAttributes(FSItem.GetAttributesRequest(), of: item) { attributes, error in
        #expect(error == nil); #expect(attributes?.inhibitKernelOffloadedIO == false)
    }
    let map = ReplyOnce(), complete = ReplyOnce(), write = ReplyOnce()
    volume.blockmapFile(item, offset: 0, length: 512, flags: [.write], operationID: .unspecified,
        packer: class_createInstance(FSExtentPacker.self, 0) as! FSExtentPacker, replyHandler: map.accept)
    volume.completeIO(for: item, offset: 0, length: 512, status: nil, flags: [.write], operationID: .unspecified, replyHandler: complete.accept)
    volume.write(contents: Data([1]), to: item, at: 0) { _, error in write.accept(error) }
    for reply in [map, complete, write] {
        reply.assertOnce(); #expect((reply.error as NSError?)?.code == Int(EROFS))
    }
}

@Test func unalignedKernelExtentIsRejectedBeforePacking() throws {
    let core = HandlerCore(), volume = try core.volume()
    core.flags = 0; core.mappingPhysical = 37
    volume.activate(options: class_createInstance(FSTaskOptions.self, 0) as! FSTaskOptions) { _, error in #expect(error == nil) }
    let item = YuzuNTFSItem(ref: 42, parent: 5)
    let reply = ReplyOnce()
    volume.blockmapFile(item, offset: 0, length: 512, flags: [], operationID: .unspecified,
        packer: class_createInstance(FSExtentPacker.self, 0) as! FSExtentPacker, replyHandler: reply.accept)
    reply.assertOnce(); #expect((reply.error as NSError?)?.code == Int(EINVAL))
}

@Test(arguments: [false, true]) func p0ForceReadOnlyHookLatchesOnNextReadOperation(closeFirst: Bool) throws {
    let core = HandlerCore(), volume = try core.volume()
    let hook = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    volume.forceReadOnlyURL = hook
    defer { try? FileManager.default.removeItem(at: hook) }
    volume.activate(options: class_createInstance(FSTaskOptions.self, 0) as! FSTaskOptions) { _, error in #expect(error == nil) }
    let item = YuzuNTFSItem(ref: 42, parent: 5)
    volume.getAttributes(FSItem.GetAttributesRequest(), of: item) { _, error in #expect(error == nil) }
    try Data().write(to: hook)
    if closeFirst {
        volume.closeItem(item, modes: [.read]) { error in #expect(error == nil) }
    } else {
        volume.getAttributes(FSItem.GetAttributesRequest(), of: item) { _, error in #expect(error == nil) }
    }
    try FileManager.default.removeItem(at: hook)
    let write = ReplyOnce()
    volume.write(contents: Data([1]), to: item, at: 0) { _, error in write.accept(error) }
    write.assertOnce(); #expect((write.error as NSError?)?.code == Int(EROFS))
    let readMap = ReplyOnce()
    volume.blockmapFile(item, offset: 0, length: 512, flags: [], operationID: .unspecified,
        packer: class_createInstance(FSExtentPacker.self, 0) as! FSExtentPacker, replyHandler: readMap.accept)
    readMap.assertOnce(); #expect((readMap.error as NSError?)?.code == Int(EROFS))
}

@Test func initialAttributeFailureRollsBackCreatedEntryAndInvalidatesVerifier() throws {
    let core = HandlerCore(), volume = try core.volume()
    var root: FSItem?
    volume.activate(options: class_createInstance(FSTaskOptions.self, 0) as! FSTaskOptions) { item, _ in root = item }
    let parent = try #require(root as? YuzuNTFSItem)
    core.failSetattr = true
    let request = FSItem.SetAttributesRequest(); request.size = 4096
    let reply = ReplyOnce()
    volume.createItem(named: FSFileName(string: "new"), type: .file, inDirectory: parent, attributes: request) { _, _, error in reply.accept(error) }
    reply.assertOnce()
    #expect((reply.error as NSError?)?.code == Int(ENOSPC))
    #expect(!core.created)
    #expect(core.removes == 1)
    #expect(parent.version != 1)
}

@Test func activationCancellationAndRootPublicationFailureBalanceEngine() throws {
    for failHold in [false, true] {
        let core = HandlerCore(), volume = try core.volume()
        core.failHold = failHold
        let activation = ReplyOnce()
        volume.activate(options: class_createInstance(FSTaskOptions.self, 0) as! FSTaskOptions) { _, error in activation.accept(error) }
        activation.assertOnce()
        if failHold {
            #expect(core.closes == 1)
        } else {
            let deactivation = ReplyOnce()
            volume.deactivate(options: [], replyHandler: deactivation.accept)
            deactivation.assertOnce()
            #expect(core.closes == 1)
        }
    }
}

@Test func invalidIORangesReplyExactlyOnceWithoutTrapping() throws {
    let core = HandlerCore(), volume = try core.volume()
    let item = YuzuNTFSItem(ref: 42, parent: 5)
    let packer = class_createInstance(FSExtentPacker.self, 0) as! FSExtentPacker
    let buffer = class_createInstance(FSMutableFileDataBuffer.self, 0) as! FSMutableFileDataBuffer
    for (offset, length) in [(Int64(-1), 1), (0, -1), (Int64.max, 1)] {
        let start = Date()
        let mapping = ReplyOnce()
        volume.blockmapFile(item, offset: offset, length: length, flags: [], operationID: .unspecified, packer: packer, replyHandler: mapping.accept)
        mapping.assertOnce(); #expect((mapping.error as NSError?)?.code == Int(EINVAL))
        let completion = ReplyOnce()
        volume.completeIO(for: item, offset: offset, length: length, status: nil, flags: [], operationID: .unspecified, replyHandler: completion.accept)
        completion.assertOnce(); #expect((completion.error as NSError?)?.code == Int(EINVAL))
        let read = ReplyOnce()
        volume.read(from: item, at: offset, length: length, into: buffer) { _, error in read.accept(error) }
        read.assertOnce(); #expect((read.error as NSError?)?.code == Int(EINVAL))
        #expect(Date().timeIntervalSince(start) < 0.5)
    }
    let write = ReplyOnce()
    volume.write(contents: Data([1]), to: item, at: Int64.max) { _, error in write.accept(error) }
    write.assertOnce(); #expect((write.error as NSError?)?.code == Int(EINVAL))
}

private final class BusyItemProbe: @unchecked Sendable {
    let item = YuzuNTFSItem(ref: 42, parent: 5)
    let done = DispatchSemaphore(value: 0)
    var result: Int?
}
@Test func retainedMappingDoesNotBlockUnrelatedHandlerForever() {
    let probe = BusyItemProbe()
    probe.item.operation = FSOperationID(rawValue: 123)
    DispatchQueue.global().async {
        do { try probe.item.normal {}; probe.result = 0 }
        catch { probe.result = (error as NSError).code }
        probe.done.signal()
    }
    let finished = probe.done.wait(timeout: .now() + 0.2)
    // Release the old implementation's wait even when the regression is RED.
    probe.item.io.lock(); probe.item.finishMapping(FSOperationID(rawValue: 123)); probe.item.io.unlock()
    #expect(finished == .success)
    if finished != .success { _ = probe.done.wait(timeout: .now() + 0.5) }
    #expect(probe.result == Int(EBUSY))
}

@Test func unknownItemsReceiveOneErrorReply() throws {
    let core = HandlerCore(), volume = try core.volume()
    let unknown = FSItem()
    let attributes = FSItem.SetAttributesRequest()
    let name = FSFileName(string: "name")
    func expectError(_ invoke: (ReplyOnce) -> Void) {
        let reply = ReplyOnce(), start = Date()
        invoke(reply); reply.assertOnce()
        #expect(reply.error != nil)
        #expect(Date().timeIntervalSince(start) < 0.5)
    }
    expectError { volume.openItem(unknown, modes: [.read], replyHandler: $0.accept) }
    expectError { volume.closeItem(unknown, modes: [.read], replyHandler: $0.accept) }
    expectError { r in volume.getAttributes(FSItem.GetAttributesRequest(), of: unknown) { _, e in r.accept(e) } }
    expectError { r in volume.setAttributes(attributes, on: unknown) { _, e in r.accept(e) } }
    expectError { r in volume.lookupItem(named: name, inDirectory: unknown) { _, _, e in r.accept(e) } }
    expectError { r in volume.createItem(named: name, type: .file, inDirectory: unknown, attributes: attributes) { _, _, e in r.accept(e) } }
    expectError { volume.removeItem(unknown, named: name, fromDirectory: unknown, replyHandler: $0.accept) }
    expectError { r in volume.renameItem(unknown, inDirectory: unknown, named: name, to: name, inDirectory: unknown, overItem: nil) { _, e in r.accept(e) } }
    expectError { volume.reclaimItem(unknown, replyHandler: $0.accept) }
    expectError { r in volume.write(contents: Data(), to: unknown, at: 0) { _, e in r.accept(e) } }
}

@Test func realVolumeHandlersReplyOnceForBridgeSuccessAndErrors() throws {
    for code: Int32 in [0, EIO, EROFS, ENOENT] {
        let core = HandlerCore(), volume = try core.volume()
        volume.activate(options: class_createInstance(FSTaskOptions.self, 0) as! FSTaskOptions) { _, error in #expect(error == nil) }
        core.failure = code
        let item = YuzuNTFSItem(ref: 42, parent: 5), directory = YuzuNTFSItem(ref: 5, parent: 5)
        let name = FSFileName(string: "name"), request = FSItem.SetAttributesRequest()
        let packer = class_createInstance(FSExtentPacker.self, 0) as! FSExtentPacker
        func check(_ expectedError: Bool, _ invoke: (ReplyOnce) -> Void) {
            let reply = ReplyOnce(), start = Date()
            invoke(reply); reply.assertOnce()
            #expect((reply.error != nil) == expectedError)
            #expect(Date().timeIntervalSince(start) < 0.5)
        }
        check(code != 0) { volume.synchronize(flags: .wait, replyHandler: $0.accept) }
        check(code != 0) { r in volume.getAttributes(FSItem.GetAttributesRequest(), of: item) { _, error in r.accept(error) } }
        check(code != 0) { r in volume.setAttributes(request, on: item) { _, error in r.accept(error) } }
        check(code != 0) { r in volume.lookupItem(named: name, inDirectory: directory) { _, _, error in r.accept(error) } }
        check(code != 0) { r in volume.lookupItem(name: name, in: directory, packer: packer) { _, _, error in r.accept(error) } }
        check(code != 0) { r in volume.createItem(named: name, type: .file, inDirectory: directory, attributes: request) { _, _, error in r.accept(error) } }
        check(code != 0) { r in volume.createFile(name: name, in: directory, attributes: request, packer: packer) { _, _, error in r.accept(error) } }
        check(code != 0) { volume.removeItem(item, named: name, fromDirectory: directory, replyHandler: $0.accept) }
        check(code != 0) { r in volume.renameItem(item, inDirectory: directory, named: name, to: name, inDirectory: directory, overItem: nil) { _, error in r.accept(error) } }
        check(code != 0) { r in volume.write(contents: Data([1]), to: item, at: 0) { _, error in r.accept(error) } }
        check(code != 0) { volume.openItem(item, modes: [.write], replyHandler: $0.accept) }
        check(false) { volume.closeItem(item, modes: [.write], replyHandler: $0.accept) }
        check(code != 0) { volume.completeIO(for: item, offset: 0, length: 0, status: nil, flags: [.write], operationID: .unspecified, replyHandler: $0.accept) }
        check(false) { volume.blockmapFile(item, offset: 0, length: 0, flags: [], operationID: .unspecified, packer: packer, replyHandler: $0.accept) }
        check(true) { r in volume.createSymbolicLink(named: name, inDirectory: directory, attributes: request, linkContents: name) { _, _, error in r.accept(error) } }
        check(true) { r in volume.createLink(to: item, named: name, inDirectory: directory) { _, error in r.accept(error) } }
        check(true) { r in volume.readSymbolicLink(item) { _, error in r.accept(error) } }
        check(false) { volume.reclaimItem(item, replyHandler: $0.accept) }
        check(false) { volume.mount(options: class_createInstance(FSTaskOptions.self, 0) as! FSTaskOptions, replyHandler: $0.accept) }
        let unmount = ReplyOnce()
        volume.unmount { unmount.accept(nil) }; unmount.assertOnce()
    }
}

@Test func namespaceRemovalDoesNotWaitForExplicitMapping() throws {
    let core = HandlerCore(), volume = try core.volume()
    volume.activate(options: class_createInstance(FSTaskOptions.self, 0) as! FSTaskOptions) { _, _ in }
    let item = YuzuNTFSItem(ref: 42, parent: 5), parent = YuzuNTFSItem(ref: 5, parent: 5)
    item.operation = FSOperationID(rawValue: 123)
    item.extents = [nb_extent(logical: 4096, physical: 4096, length: 512, kind: UInt32(NB_EXT_DATA))]
    let name = FSFileName(string: "name"), remove = ReplyOnce(), rename = ReplyOnce()
    volume.removeItem(item, named: name, fromDirectory: parent, replyHandler: remove.accept)
    volume.renameItem(item, inDirectory: parent, named: name, to: name, inDirectory: parent, overItem: item) { _, error in rename.accept(error) }
    remove.assertOnce(); rename.assertOnce()
    #expect(remove.error == nil); #expect(rename.error == nil)
    let request = FSItem.SetAttributesRequest(); request.size = 0
    let busy = ReplyOnce()
    volume.setAttributes(request, on: item) { _, error in busy.accept(error) }
    busy.assertOnce(); #expect((busy.error as NSError?)?.code == Int(EBUSY))
    item.io.lock(); item.finishMapping(FSOperationID(rawValue: 123)); item.io.unlock()
    let completed = ReplyOnce()
    volume.setAttributes(request, on: item) { _, error in completed.accept(error) }
    completed.assertOnce(); #expect(completed.error == nil)
}

@Test func concurrentGrowthCannotTurnOldGrowthSnapshotIntoUnsafeShrink() throws {
    let core = HandlerCore(), volume = try core.volume()
    volume.activate(options: class_createInstance(FSTaskOptions.self, 0) as! FSTaskOptions) { _, _ in }
    let item = YuzuNTFSItem(ref: 42, parent: 5)
    volume.beforeSizeLock = {
        volume.beforeSizeLock = nil
        let growth = FSItem.SetAttributesRequest(); growth.size = 16384
        volume.setAttributes(growth, on: item) { _, error in #expect(error == nil) }
        item.io.lock()
        item.operation = FSOperationID(rawValue: 55)
        item.extents = [nb_extent(logical: 12288, physical: 65536, length: 4096, kind: UInt32(NB_EXT_DATA))]
        item.io.unlock()
    }
    let staleGrowth = FSItem.SetAttributesRequest(); staleGrowth.size = 12288
    let reply = ReplyOnce()
    volume.setAttributes(staleGrowth, on: item) { _, error in reply.accept(error) }
    reply.assertOnce(); #expect((reply.error as NSError?)?.code == Int(EBUSY))
    #expect(core.size == 16384)
    #expect(item.extents.first?.physical == 65536)
}

@Test func completionMapsUnrepresentableErrorCodeToEIO() throws {
    let core = HandlerCore(), volume = try core.volume()
    volume.activate(options: class_createInstance(FSTaskOptions.self, 0) as! FSTaskOptions) { _, _ in }
    let item = YuzuNTFSItem(ref: 42, parent: 5), reply = ReplyOnce()
    volume.completeIO(for: item, offset: 0, length: 0, status: NSError(domain: "test", code: Int.max), flags: [.write], operationID: .unspecified, replyHandler: reply.accept)
    reply.assertOnce()
    #expect(core.completedStatus == EIO)
}
@Test func overflowingReferenceRepliesWithErrorRatherThanTrapping() throws {
    let core = HandlerCore(), volume = try core.volume()
    volume.activate(options: class_createInstance(FSTaskOptions.self, 0) as! FSTaskOptions) { _, _ in }
    let item = YuzuNTFSItem(ref: UInt64.max, parent: 5), reply = ReplyOnce()
    volume.getAttributes(FSItem.GetAttributesRequest(), of: item) { _, error in reply.accept(error) }
    reply.assertOnce(); #expect((reply.error as NSError?)?.code == Int(EOVERFLOW))
}

private final class OversizedBlockResource: FSBlockDeviceResource {
    override var blockSize: UInt64 { UInt64.max }
    override var blockCount: UInt64 { 2 }
    override var physicalBlockSize: UInt64 { 4096 }
}
// The SDK exposes no block-resource initializer. A zeroed raw instance owns
// descriptor 0: its deallocator closes stdin, racing other tests that reuse it
// for an image. Guard the SDK's actual ivar type/offset BEFORE allocating, then
// give this geometry-only test double the standard invalid descriptor (-1).
// No real resource is opened, and no private layout assumption ships in Module.
private func oversizedResource() throws -> OversizedBlockResource {
    let descriptor = try #require(class_getInstanceVariable(FSBlockDeviceResource.self, "_fileDescriptor"))
    let encoding = try #require(ivar_getTypeEncoding(descriptor))
    try #require(String(cString: encoding) == "i", "SDK resource descriptor layout changed")
    let resource = class_createInstance(OversizedBlockResource.self, 0) as! OversizedBlockResource
    Unmanaged.passUnretained(resource).toOpaque().advanced(by: ivar_getOffset(descriptor))
        .storeBytes(of: Int32(-1), as: Int32.self)
    return resource
}
@Test func geometryStubDoesNotOwnProcessDescriptorZero() throws {
    let resource = try oversizedResource()
    let descriptor = try #require(class_getInstanceVariable(FSBlockDeviceResource.self, "_fileDescriptor"))
    let fd = Unmanaged.passUnretained(resource).toOpaque().advanced(by: ivar_getOffset(descriptor)).load(as: Int32.self)
    #expect(fd == -1)
}
@Test func unrepresentableDeviceGeometryIsAnErrorNotATrap() throws {
    let resource = try oversizedResource()
    do {
        _ = try YuzuNTFSDevice(resource)
        Issue.record("Invalid resource geometry was accepted")
    } catch {
        #expect([Int(EINVAL), Int(EOVERFLOW)].contains((error as NSError).code))
    }
}

@Test func geometryOverflowRepliesFromFilesystemHandlers() throws {
    let filesystem = YuzuNTFSFileSystem()
    let resource = try oversizedResource()
    let probe = ReplyOnce(), load = ReplyOnce()
    filesystem.probeResource(resource: resource) { _, error in probe.accept(error) }
    filesystem.loadResource(resource: resource, options: class_createInstance(FSTaskOptions.self, 0) as! FSTaskOptions) { _, error in load.accept(error) }
    probe.assertOnce(); load.assertOnce()
    #expect((probe.error as NSError?)?.code == Int(EOVERFLOW))
    #expect((load.error as NSError?)?.code == Int(EOVERFLOW))
}

@Test func invalidGeometryProductsAndPhysicalRangesAreChecked() {
    for (size, count, physical): (UInt64, UInt64, UInt64) in [
        (512, UInt64.max, 512), (4096, 1, UInt64.max), (0, 1, 512), (512, 0, 512)
    ] {
        #expect(throws: (any Error).self) {
            _ = try YuzuNTFSGeometry(blockSize: size, blockCount: count, physicalBlockSize: physical)
        }
    }
    #expect(YuzuNTFSBoundary.errorCode(NSError(domain: "test", code: Int.min)) == EIO)
    #expect(throws: (any Error).self) { _ = try YuzuNTFSBoundary.adding(UInt64.max, 1) }
    #expect(throws: (any Error).self) { _ = try YuzuNTFSBoundary.offset(UInt64.max) }
}

@Test func overflowingBridgeCookieAndPhysicalRangeReplyOnce() throws {
    let core = HandlerCore(), volume = try core.volume()
    volume.activate(options: class_createInstance(FSTaskOptions.self, 0) as! FSTaskOptions) { _, _ in }
    core.mappingPhysical = UInt64.max
    core.directoryCookie = UInt64.max
    let map = ReplyOnce(), enumeration = ReplyOnce()
    volume.blockmapFile(YuzuNTFSItem(ref: 42, parent: 5), offset: 0, length: 512, flags: [], operationID: .unspecified,
        packer: class_createInstance(FSExtentPacker.self, 0) as! FSExtentPacker, replyHandler: map.accept)
    volume.enumerateDirectory(YuzuNTFSItem(ref: 5, parent: 5), startingAt: FSDirectoryCookie(rawValue: 0),
        verifier: FSDirectoryVerifier(rawValue: 0), attributes: FSItem.GetAttributesRequest(),
        packer: class_createInstance(FSDirectoryEntryPacker.self, 0) as! FSDirectoryEntryPacker) { _, error in enumeration.accept(error) }
    map.assertOnce(); enumeration.assertOnce()
    #expect((map.error as NSError?)?.code == Int(EOVERFLOW))
    #expect((enumeration.error as NSError?)?.code == Int(EOVERFLOW))
}
