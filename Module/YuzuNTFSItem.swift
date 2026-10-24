// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import FSKit
import NTFSBridge

enum YuzuNTFSBoundary {
    static func errorCode(_ error: any Error) -> Int32 {
        Int32(exactly: (error as NSError).code) ?? EIO
    }
    static func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw POSIXError(.EOVERFLOW) }
        return sum
    }
    static func offset(_ value: UInt64) throws -> off_t {
        guard let offset = off_t(exactly: value) else { throw POSIXError(.EOVERFLOW) }
        return offset
    }
}

struct YuzuNTFSGeometry {
    let sector: Int
    let bridgeSector: UInt32
    let bytes: UInt64
    let probeLength: Int
    init(blockSize: UInt64, blockCount: UInt64, physicalBlockSize: UInt64) throws {
        guard let sector = Int(exactly: blockSize), let bridgeSector = UInt32(exactly: blockSize),
              let physical = Int(exactly: physicalBlockSize) else { throw POSIXError(.EOVERFLOW) }
        guard sector == 512 || sector == 4096, blockCount > 0,
              physical > 0, physical <= 1_048_576, physical.nonzeroBitCount == 1 else { throw POSIXError(.EINVAL) }
        let (bytes, overflow) = blockSize.multipliedReportingOverflow(by: blockCount)
        guard !overflow, bytes <= UInt64(Int64.max) else { throw POSIXError(.EOVERFLOW) }
        self.sector = sector; self.bridgeSector = bridgeSector; self.bytes = bytes
        probeLength = max(512, sector, physical)
    }
}

final class YuzuNTFSItem: FSItem {
    let ref: UInt64
    var parent: UInt64
    var version: UInt64 = 1
    // Q-R1: fixed before first publication, never a read-only revocation tool.
    var inhibitsKernelIO: Bool?
    let io = NSCondition()
    private let completionLock = NSLock()
    // One explicit write owns the shrink-protection lease; repeated write maps
    // with the same ID append extents. Read/unspecified maps never own a lease:
    // the kernel may retain those mappings without a completion callback.
    var operation: FSOperationID?
    var extents: [nb_extent] = []
    var releasePin: (() -> Void)?
    init(ref: UInt64, parent: UInt64) { self.ref = ref; self.parent = parent; super.init() }
    deinit { releasePin?() }
    func normal<T>(_ body: () throws -> T) throws -> T {
        io.lock(); defer { io.unlock() }
        guard operation == nil else { throw POSIXError(.EBUSY) }
        return try body()
    }
    func changingSize<T>(_ body: () throws -> T) rethrows -> T {
        io.lock(); defer { io.unlock() }
        return try body()
    }
    // Called only while changingSize holds io, with the volume lock held too.
    func checkShrink(to size: UInt64, currentSize: UInt64) throws {
        guard size < currentSize, operation != nil else { return }
        if extents.contains(where: {
            $0.length > UInt64.max - $0.logical || $0.logical + $0.length > size
        }) { throw POSIXError(.EBUSY) }
    }
    static func mutating<T>(_ first: YuzuNTFSItem, replacing second: YuzuNTFSItem?, _ body: () throws -> T) throws -> T {
        guard let second, second !== first else { return try first.normal(body) }
        let low = first.ref < second.ref ? first : second
        let high = first.ref < second.ref ? second : first
        return try low.normal { try high.normal(body) }
    }
    // Serialize arrived metadata completions independently of outstanding map
    // ownership. Waiting for an unrelated map would reorder cached writes:
    // the later owner's VDL gap zeroing could erase the earlier payload.
    func completing<T>(_ id: FSOperationID, _ body: () throws -> T) rethrows -> T {
        completionLock.lock(); defer { completionLock.unlock() }
        io.lock(); defer { finishMapping(id); io.unlock() }
        return try body()
    }
    func finishMapping(_ id: FSOperationID) {
        guard id != .unspecified, operation == id else { return }
        operation = nil
        extents.removeAll(keepingCapacity: true)
        io.broadcast()
    }
}

final class WeakNTFSItem {
    weak var item: YuzuNTFSItem?
    init(_ item: YuzuNTFSItem) { self.item = item }
}

/// The volume uses this same recursive lock for bridge calls, publication and
/// successful tryReclaim. No gap exists between identity lookup and SDK reply.
final class YuzuNTFSItemTable {
    private var items: [UInt64: WeakNTFSItem] = [:]
    let lock = NSRecursiveLock()
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
    func publish(ref: UInt64, parent: UInt64, initialize: (YuzuNTFSItem) throws -> Void,
                 reply: (YuzuNTFSItem) -> Void) rethrows {
        try withLock {
            let item = item(ref: ref, parent: parent)
            try initialize(item)
            reply(item)
        }
    }
    func existing(ref: UInt64) -> YuzuNTFSItem? { withLock { items[ref]?.item } }
    func item(ref: UInt64, parent: UInt64) -> YuzuNTFSItem {
        withLock {
            if let item = items[ref]?.item { return item }
            let item = YuzuNTFSItem(ref: ref, parent: parent)
            items[ref] = WeakNTFSItem(item)
            return item
        }
    }
    func forget(_ item: YuzuNTFSItem) {
        withLock {
            guard items[item.ref]?.item === item else { return }
            items.removeValue(forKey: item.ref)
            let release = item.releasePin
            item.releasePin = nil
            release?()
        }
    }
    func removeAll() { withLock { items.removeAll() } }
}

/// Stream bounded bridge prefixes to the SDK packer. ENOBUFS is successful
/// partial progress, not a corrupt/unsupported mapping. No per-batch heap array.
enum YuzuNTFSMapping {
    static func map(api: nb_engine, core: OpaquePointer?, ref: UInt64, offset: UInt64,
                    length: UInt64, write: Bool, preservingWrite: Bool = false,
                    consume: (UnsafeBufferPointer<nb_extent>) throws -> Bool) throws {
        try ranges(api: api, core: core, ref: ref, offset: offset, length: length, write: write,
                   physicalOnly: false, preservingWrite: preservingWrite && !write, consume: consume)
    }
    static func query(api: nb_engine, core: OpaquePointer?, ref: UInt64, offset: UInt64,
                      length: UInt64, consume: (UnsafeBufferPointer<nb_extent>) throws -> Bool) throws {
        try ranges(api: api, core: core, ref: ref, offset: offset, length: length, write: false,
                   physicalOnly: true, preservingWrite: false, consume: consume)
    }
    private static func ranges(api: nb_engine, core: OpaquePointer?, ref: UInt64, offset: UInt64,
                               length: UInt64, write: Bool, physicalOnly: Bool, preservingWrite: Bool,
                               consume: (UnsafeBufferPointer<nb_extent>) throws -> Bool) throws {
        guard length <= UInt64.max - offset else { throw POSIXError(.EFBIG) }
        try withUnsafeTemporaryAllocation(of: nb_extent.self, capacity: 128) { buffer in
            let end = offset + length
            var cursor = offset
            while cursor < end {
                var count = 0
                let rc: Int32
                if physicalOnly {
                    rc = api.nb_query_extents!(core, ref, cursor, end - cursor, buffer.baseAddress, buffer.count, &count)
                } else if preservingWrite {
                    rc = api.nb_read_map_during_write!(core, ref, cursor, end - cursor, buffer.baseAddress, buffer.count, &count)
                } else {
                    rc = api.nb_blockmap!(core, ref, cursor, end - cursor, write ? 1 : 0, buffer.baseAddress, buffer.count, &count)
                }
                guard rc == 0 || rc == ENOBUFS else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(rc)) }
                guard count > 0, count <= buffer.count else { throw POSIXError(.EIO) }
                let batch = UnsafeBufferPointer(start: buffer.baseAddress, count: count)
                let last = batch[count - 1]
                guard last.logical >= cursor, last.length > 0,
                      last.logical <= end, last.length <= end - last.logical else { throw POSIXError(.EIO) }
                if try !consume(batch) { return }
                cursor = last.logical + last.length
            }
        }
    }
}
