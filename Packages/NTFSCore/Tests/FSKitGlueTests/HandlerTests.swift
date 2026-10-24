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
    var flags: UInt32 = UInt32(NB_RESIDENT)
    var mounts = 0
    var closes = 0
    var removes = 0
    var created = false
    var failHold = false
    var failSetattr = false
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
        api.nb_statfs = { core, out in let s = HandlerCore.state(core); out!.pointee.read_only = s.readOnly ? 1 : 0; return s.failure }
        api.nb_getattr = { core, ref, parent, out in
            let s = HandlerCore.state(core); if s.failure != 0 { return s.failure }
            out!.pointee = nb_attr(); out!.pointee.ref = ref; out!.pointee.parent_ref = parent
            out!.pointee.type = ref == 5 ? NB_DIR : NB_FILE; out!.pointee.flags = s.flags; return 0
        }
        api.nb_lookup = { core, _, _, _, out in let s = HandlerCore.state(core); out!.pointee.ref = 42; out!.pointee.parent_ref = 5; return s.failure }
        api.nb_create = { core, _, _, _, _, out in let s = HandlerCore.state(core); if s.failure != 0 { return s.failure }; s.created = true; out!.pointee.ref = 42; out!.pointee.parent_ref = 5; return 0 }
        api.nb_setattr = { core, _, _, _ in let s = HandlerCore.state(core); return s.failSetattr ? ENOSPC : s.failure }
        api.nb_remove = { core, _, _, _ in let s = HandlerCore.state(core); s.removes += 1; s.created = false; return s.failure }
        api.nb_rename = { core, _, _, _, _, _, _ in HandlerCore.state(core).failure }
        api.nb_read = { core, _, _, _, _, got in got!.pointee = 0; return HandlerCore.state(core).failure }
        api.nb_write = { core, _, _, _, _ in HandlerCore.state(core).failure }
        api.nb_complete_io = { core, _, _, _, _, _ in HandlerCore.state(core).failure }
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
