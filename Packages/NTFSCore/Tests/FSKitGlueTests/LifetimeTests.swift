// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Dispatch
import Darwin
import Testing
import FSKit
import NTFSBridge
import EngineE2
@testable import FSKitGlue

private final class PublicationProbe: @unchecked Sendable {
    let table = YuzuNTFSItemTable()
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = false
    var reclaimedDuringReply: Bool { lock.withLock { entered } }
    func tryReclaim() {
        if table.lock.try() {
            lock.withLock { entered = true }
            table.lock.unlock()
        }
        done.signal()
    }
}

@Test func publicationExcludesConcurrentReclaimUntilReplyReturns() {
    let probe = PublicationProbe()
    probe.table.publish(ref: 42, parent: 5, initialize: { _ in }) { item in
        DispatchQueue.global().async { probe.tryReclaim() }
        #expect(probe.done.wait(timeout: .now() + 5) == .success)
        #expect(!probe.reclaimedDuringReply)
        #expect(probe.table.item(ref: 42, parent: 5) === item)
    }
    #expect(probe.table.lock.try())
    probe.table.lock.unlock()
}

@Test func unrelatedAndCachedCompletionsPreserveMappedOperation() {
    let item = YuzuNTFSItem(ref: 42, parent: 5)
    let first = FSOperationID(rawValue: 11), second = FSOperationID(rawValue: 12)
    item.io.lock(); defer { item.io.unlock() }
    item.operation = first
    item.extents = [nb_extent(logical: 0, physical: 4096, length: 4096, kind: UInt32(NB_EXT_DATA))]
    item.finishMapping(second)
    #expect(item.operation == first)
    #expect(item.extents.count == 1)
    item.finishMapping(.unspecified)
    #expect(item.operation == first)
    #expect(item.extents.count == 1)
    item.finishMapping(first)
    #expect(item.operation == nil)
    #expect(item.extents.isEmpty)
}

private final class OfflineVolume {
    let api = nb_engine_e2()!.pointee
    let image: URL
    let fd: Int32
    var core: OpaquePointer?
    var dev = nb_blockdev()
    init() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        image = FileManager.default.temporaryDirectory.appendingPathComponent("yuzu-glue-\(UUID()).img")
        try FileManager.default.copyItem(at: repository.appendingPathComponent("fixtures/basic-512.img"), to: image)
        fd = open(image.path, O_RDWR)
        try #require(fd >= 0)
        var s = Darwin.stat(); try #require(fstat(fd, &s) == 0)
        dev = nb_blockdev(ctx: UnsafeMutableRawPointer(bitPattern: Int(fd) + 1), size: UInt64(s.st_size), sector_size: 512,
            read: { ctx, off, buf, len in
                let fd = Int32(Int(bitPattern: ctx) - 1)
                var done = 0
                while done < len {
                    let n = pread(fd, buf!.advanced(by: done), len - done, off_t(off) + off_t(done))
                    if n < 0 { if errno == EINTR { continue }; return errno }; if n == 0 { return EIO }; done += n
                }; return 0
            }, write: { ctx, off, buf, len in
                let fd = Int32(Int(bitPattern: ctx) - 1)
                var done = 0
                while done < len {
                    let n = pwrite(fd, buf!.advanced(by: done), len - done, off_t(off) + off_t(done))
                    if n < 0 { if errno == EINTR { continue }; return errno }; if n == 0 { return EIO }; done += n
                }; return 0
            }, flush: { ctx in fsync(Int32(Int(bitPattern: ctx) - 1)) == 0 ? 0 : errno })
        try #require(api.nb_mount!(&dev, 1, &core) == 0)
    }
    deinit { if let core { _ = api.nb_unmount!(core) }; close(fd); try? FileManager.default.removeItem(at: image) }
    func remount() throws {
        try #require(api.nb_unmount!(core) == 0); core = nil
        try #require(api.nb_mount!(&dev, 1, &core) == 0)
    }
    var root: UInt64 { api.nb_root_ref!(core) }
    func create(_ name: String) throws -> nb_attr {
        var a = nb_attr(); let u = Array(name.utf16)
        try #require(api.nb_create!(core, root, u, u.count, UInt32(NB_FILE), &a) == 0)
        return a
    }
    func writeCluster(_ ref: UInt64, at offset: UInt64) throws {
        var e = nb_extent(), count = 0
        try #require(api.nb_blockmap!(core, ref, offset, 4096, 1, &e, 1, &count) == 0)
        try #require(count == 1)
        let data = [UInt8](repeating: 0x5a, count: 4096)
        try #require(data.withUnsafeBytes { pwrite(fd, $0.baseAddress, 4096, off_t(e.physical)) } == 4096)
        try #require(api.nb_complete_io!(core, ref, offset, 4096, 0, 1) == 0)
    }
}

@Test func removedAndReplacedItemsRetainAllocationUntilReclaim() throws {
    let v = try OfflineVolume(), table = YuzuNTFSItemTable()
    let hold = try #require(v.api.nb_hold), release = try #require(v.api.nb_release)
    let victim = try v.create("victim"), source = try v.create("source")
    try v.writeCluster(victim.ref, at: 0)
    var live: YuzuNTFSItem?
    try table.publish(ref: victim.ref, parent: v.root, initialize: { item in
        try #require(hold(v.core, item.ref) == 0)
        item.releasePin = { #expect(release(v.core, victim.ref) == 0) }
    }, reply: { live = $0 })
    let oldName = Array("victim".utf16), src = Array("source".utf16)
    try #require(v.api.nb_rename!(v.core, v.root, src, src.count, v.root, oldName, oldName.count) == 0)
    var a = nb_attr()
    try #require(v.api.nb_getattr!(v.core, victim.ref, v.root, &a) == 0)
    #expect(a.size == 4096)
    for i in 0..<32 { #expect(try v.create("reuse-\(i)").ref != victim.ref) }
    var before = nb_stat(), after = nb_stat()
    try #require(v.api.nb_statfs!(v.core, &before) == 0)
    table.withLock { table.forget(live!) }
    try #require(v.api.nb_statfs!(v.core, &after) == 0)
    #expect(after.free_blocks > before.free_blocks)
    #expect(live!.releasePin == nil)
    // Unlink a pinned source too, rather than only testing replacement.
    try #require(hold(v.core, source.ref) == 0)
    try #require(v.api.nb_remove!(v.core, v.root, oldName, oldName.count) == 0)
    try #require(v.api.nb_getattr!(v.core, source.ref, v.root, &a) == 0)
    try #require(release(v.core, source.ref) == 0)
}

@Test func mapsMoreThan128RealFragmentedExtents() throws {
    let v = try OfflineVolume(), target = try v.create("fragmented-target")
    for i in 0..<140 {
        try v.writeCluster(target.ref, at: UInt64(i * 4096))
        let blocker = try v.create("blocker-\(i)")
        try v.writeCluster(blocker.ref, at: 0)
    }
    var extents = 0, end: UInt64 = 0
    try YuzuNTFSMapping.map(api: v.api, core: v.core, ref: target.ref, offset: 0, length: 140 * 4096, write: false) { batch in
        for e in batch { #expect(e.logical == end); end += e.length; extents += 1 }
        return true
    }
    #expect(extents > 128)
    #expect(end == 140 * 4096)
    var queried = 0, queryEnd: UInt64 = 0
    try YuzuNTFSMapping.query(api: v.api, core: v.core, ref: target.ref, offset: 0, length: 140 * 4096) { batch in
        for extent in batch { #expect(extent.logical == queryEnd); queryEnd += extent.length; queried += 1 }
        return true
    }
    #expect(queried == extents)
    #expect(queryEnd == end)
}

private final class CachedCompletion: @unchecked Sendable {
    let volume: OfflineVolume
    let item: YuzuNTFSItem
    let arrived = DispatchSemaphore(value: 0)
    let applied = DispatchSemaphore(value: 0)
    var result: Int32 = -1 // Read only after the applied semaphore synchronizes.
    init(volume: OfflineVolume, item: YuzuNTFSItem) { self.volume = volume; self.item = item }
    func apply() {
        arrived.signal()
        item.completing(.unspecified) {
            result = volume.api.nb_complete_io!(volume.core, item.ref, 4096, 4096, 0, 1)
        }
        applied.signal()
    }
}

@Test func cachedCompletionDeliveredBeforeLaterRangePreservesPayloadAfterRemount() throws {
    let v = try OfflineVolume(), file = try v.create("completion-order")
    try v.writeCluster(file.ref, at: 0) // EOF and VDL both 4096.
    var cached = nb_extent(), later = nb_extent(), count = 0
    try #require(v.api.nb_blockmap!(v.core, file.ref, 4096, 4096, 1, &cached, 1, &count) == 0)
    try #require(count == 1)
    try #require(v.api.nb_blockmap!(v.core, file.ref, 8192, 4096, 1, &later, 1, &count) == 0)
    try #require(count == 1)
    let a = Data(repeating: 0xa5, count: 4096), b = Data(repeating: 0xb6, count: 4096)
    try #require(a.withUnsafeBytes { pwrite(v.fd, $0.baseAddress, 4096, off_t(cached.physical)) } == 4096)
    try #require(b.withUnsafeBytes { pwrite(v.fd, $0.baseAddress, 4096, off_t(later.physical)) } == 4096)
    let item = YuzuNTFSItem(ref: file.ref, parent: v.root), owner = FSOperationID(rawValue: 22)
    item.operation = owner; item.extents = [later]
    let completion = CachedCompletion(volume: v, item: item)
    DispatchQueue.global().async { completion.apply() }
    try #require(completion.arrived.wait(timeout: .now() + 5) == .success)
    let beforeB = completion.applied.wait(timeout: .now() + 0.25)
    #expect(beforeB == .success, "An arrived cached completion must not wait behind B's outstanding map")
    item.io.lock()
    #expect(item.operation == owner)
    #expect(item.extents.count == 1)
    item.io.unlock()
    let rc = item.completing(owner) { v.api.nb_complete_io!(v.core, file.ref, 8192, 4096, 0, 1) }
    try #require(rc == 0)
    if beforeB != .success { try #require(completion.applied.wait(timeout: .now() + 5) == .success) }
    try #require(completion.result == 0)
    #expect(item.operation == nil)
    try v.remount()
    var bytes = Data(count: 12288), got = 0
    try #require(bytes.withUnsafeMutableBytes { v.api.nb_read!(v.core, file.ref, 0, $0.baseAddress, $0.count, &got) } == 0)
    #expect(got == 12288)
    #expect(bytes == Data(repeating: 0x5a, count: 4096) + a + b)
}
