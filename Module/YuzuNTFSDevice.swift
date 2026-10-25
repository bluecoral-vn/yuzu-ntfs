// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import FSKit
import NTFSBridge

protocol YuzuNTFSDeviceAccess: AnyObject {
    var blockdev: nb_blockdev { get }
    var extentResource: FSBlockDeviceResource? { get }
    var metadataActive: Bool { get set }
    func purge<Extents: Collection>(_ extents: Extents) throws where Extents.Element == nb_extent
}

/// Fixed device-sector cache keys: FSKit forbids overlapping metadata buffers.
/// The bridge also performs sub-sector probes and edge zeroing, hence RMW here.
final class YuzuNTFSDevice: YuzuNTFSDeviceAccess {
    let resource: FSBlockDeviceResource
    var extentResource: FSBlockDeviceResource? { resource }
    private let lock = NSRecursiveLock()
    private var active = false
    var metadataActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return active }
        set { lock.lock(); defer { lock.unlock() }; active = newValue }
    }
    private var cached = Set<Int64>()
    private let scratch: UnsafeMutableRawPointer
    private let geometry: YuzuNTFSGeometry
    init(_ resource: FSBlockDeviceResource) throws {
        let geometry = try YuzuNTFSGeometry(blockSize: resource.blockSize, blockCount: resource.blockCount, physicalBlockSize: resource.physicalBlockSize)
        self.resource = resource
        self.geometry = geometry
        scratch = .allocate(byteCount: geometry.sector, alignment: 4096)
    }
    deinit { scratch.deallocate() }
    var blockdev: nb_blockdev {
        nb_blockdev(ctx: Unmanaged.passUnretained(self).toOpaque(),
                    size: geometry.bytes, sector_size: geometry.bridgeSector,
                    read: { ctx, off, buf, len in
            Unmanaged<YuzuNTFSDevice>.fromOpaque(ctx!).takeUnretainedValue().transfer(off, buf!, len, write: false)
        }, write: { ctx, off, buf, len in
            Unmanaged<YuzuNTFSDevice>.fromOpaque(ctx!).takeUnretainedValue().transfer(off, UnsafeMutableRawPointer(mutating: buf!), len, write: true)
        }, flush: { ctx in
            let device = Unmanaged<YuzuNTFSDevice>.fromOpaque(ctx!).takeUnretainedValue()
            do { if device.metadataActive { try device.resource.metadataFlush() }; return 0 }
            catch { return YuzuNTFSBoundary.errorCode(error) }
        })
    }
    private func transfer(_ offset: UInt64, _ buffer: UnsafeMutableRawPointer, _ length: Int, write: Bool) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard length >= 0, offset <= geometry.bytes, UInt64(length) <= geometry.bytes - offset else { return EOVERFLOW }
        let sector = geometry.sector
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
        } catch { return YuzuNTFSBoundary.errorCode(error) }
    }
    static func overlappingMetadataSectors<Extents: Collection>(_ cached: Set<Int64>, _ extents: Extents,
                                                               sector: UInt64) throws -> Set<Int64> where Extents.Element == nb_extent {
        guard sector > 0 else { throw POSIXError(.EINVAL) }
        var touched = Set<Int64>()
        for extent in extents where extent.kind != NB_EXT_HOLE && extent.length != 0 {
            let end = try YuzuNTFSBoundary.adding(extent.physical, extent.length)
            let first = extent.physical / sector * sector
            let last = (end - 1) / sector * sector
            let sectors = (last - first) / sector + 1
            if sectors < UInt64(cached.count) {
                // Small I/O must not scan all metadata accumulated by the
                // volume: that made create/copy O(number of files squared).
                var position = first
                while true {
                    let base = try YuzuNTFSBoundary.offset(position)
                    if cached.contains(base) { touched.insert(base) }
                    if position == last { break }
                    position += sector
                }
            } else {
                // Large sequential extents are cheaper to intersect with the
                // small metadata set than to visit every data sector.
                for base in cached {
                    guard let start = UInt64(exactly: base) else { throw POSIXError(.EIO) }
                    let sectorEnd = try YuzuNTFSBoundary.adding(start, sector)
                    if start < end && sectorEnd > extent.physical { touched.insert(base) }
                }
            }
        }
        return touched
    }
    /// Purge only engine-touched sectors before handing them to kernel data I/O.
    func purge<Extents: Collection>(_ extents: Extents) throws where Extents.Element == nb_extent {
        lock.lock(); defer { lock.unlock() }
        guard metadataActive else { return }
        let sector = UInt64(geometry.sector)
        let touched = try Self.overlappingMetadataSectors(cached, extents, sector: sector)
        guard !touched.isEmpty else { return }
        try resource.metadataFlush()
        try resource.metadataPurge(touched.map { FSMetadataRange(offset: $0, segmentLength: sector, segmentCount: 1) })
        cached.subtract(touched)
    }
}
