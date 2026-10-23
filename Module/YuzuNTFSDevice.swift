// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import FSKit
import NTFSBridge

/// Fixed device-sector cache keys: FSKit forbids overlapping metadata buffers.
/// The bridge also performs sub-sector probes and edge zeroing, hence RMW here.
final class YuzuNTFSDevice {
    let resource: FSBlockDeviceResource
    private let lock = NSRecursiveLock()
    private var active = false
    var metadataActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return active }
        set { lock.lock(); defer { lock.unlock() }; active = newValue }
    }
    private var cached = Set<Int64>()
    private let scratch: UnsafeMutableRawPointer
    init(_ resource: FSBlockDeviceResource) {
        self.resource = resource
        scratch = .allocate(byteCount: Int(resource.blockSize), alignment: 4096)
    }
    deinit { scratch.deallocate() }
    var blockdev: nb_blockdev {
        nb_blockdev(ctx: Unmanaged.passUnretained(self).toOpaque(),
                    size: resource.blockCount * UInt64(resource.blockSize), sector_size: UInt32(resource.blockSize),
                    read: { ctx, off, buf, len in
            Unmanaged<YuzuNTFSDevice>.fromOpaque(ctx!).takeUnretainedValue().transfer(off, buf!, len, write: false)
        }, write: { ctx, off, buf, len in
            Unmanaged<YuzuNTFSDevice>.fromOpaque(ctx!).takeUnretainedValue().transfer(off, UnsafeMutableRawPointer(mutating: buf!), len, write: true)
        }, flush: { ctx in
            let device = Unmanaged<YuzuNTFSDevice>.fromOpaque(ctx!).takeUnretainedValue()
            do { if device.metadataActive { try device.resource.metadataFlush() }; return 0 }
            catch { return Int32((error as NSError).code) }
        })
    }
    private func transfer(_ offset: UInt64, _ buffer: UnsafeMutableRawPointer, _ length: Int, write: Bool) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard offset <= UInt64(Int64.max), UInt64(length) <= UInt64(Int64.max) - offset else { return EFBIG }
        let sector = Int(resource.blockSize)
        do {
            var done = 0
            while done < length {
                let position = Int64(offset) + Int64(done)
                let base = position / Int64(sector) * Int64(sector)
                let within = Int(position - base)
                let count = min(length - done, sector - within)
                let whole = within == 0 && count == sector
                let target = whole ? buffer.advanced(by: done) : scratch
                if !write || !whole {
                    if metadataActive {
                        try resource.metadataRead(into: UnsafeMutableRawBufferPointer(start: target, count: sector), startingAt: base, length: sector)
                        cached.insert(base)
                    } else {
                        guard try resource.read(into: UnsafeMutableRawBufferPointer(start: target, count: sector), startingAt: base, length: sector) == sector else { return EIO }
                    }
                }
                if write {
                    if !whole { scratch.advanced(by: within).copyMemory(from: buffer.advanced(by: done), byteCount: count) }
                    if metadataActive {
                        try resource.metadataWrite(from: UnsafeRawBufferPointer(start: target, count: sector), startingAt: base, length: sector)
                        cached.insert(base)
                    } else {
                        guard try resource.write(from: UnsafeRawBufferPointer(start: target, count: sector), startingAt: base, length: sector) == sector else { return EIO }
                    }
                } else if !whole { buffer.advanced(by: done).copyMemory(from: scratch.advanced(by: within), byteCount: count) }
                done += count
            }
            return 0
        } catch { return Int32((error as NSError).code) }
    }
    /// Purge only engine-touched sectors before handing them to kernel data I/O.
    func purge(_ extents: [nb_extent]) throws {
        lock.lock(); defer { lock.unlock() }
        guard metadataActive else { return }
        let sector = Int64(resource.blockSize)
        let touched = cached.filter { base in extents.contains { extent in
            extent.kind != NB_EXT_HOLE && UInt64(base) < extent.physical + extent.length && UInt64(base + sector) > extent.physical
        } }
        guard !touched.isEmpty else { return }
        try resource.metadataFlush()
        try resource.metadataPurge(touched.map { FSMetadataRange(offset: $0, segmentLength: UInt64(sector), segmentCount: 1) })
        cached.subtract(touched)
    }
}
