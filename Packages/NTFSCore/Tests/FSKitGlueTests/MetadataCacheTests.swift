// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
import NTFSBridge
@testable import FSKitGlue

@Test func metadataPurgeCoversEdgesAndDeduplicatesPhysicalSectors() throws {
    let cached: Set<Int64> = [0, 512, 1024, 4096]
    let extents = [nb_extent(logical: 0, physical: 513, length: 512, kind: UInt32(NB_EXT_DATA)),
                   nb_extent(logical: 512, physical: 512, length: 1, kind: UInt32(NB_EXT_DATA)),
                   nb_extent(logical: 513, physical: 0, length: 1, kind: UInt32(NB_EXT_UNINIT)),
                   nb_extent(logical: 514, physical: 4096, length: 512, kind: UInt32(NB_EXT_HOLE))]
    #expect(try YuzuNTFSDevice.overlappingMetadataSectors(cached, extents, sector: 512) == [0, 512, 1024])
    let huge = [nb_extent(logical: 0, physical: 0, length: UInt64(Int64.max), kind: UInt32(NB_EXT_DATA))]
    let empty = [nb_extent(logical: 0, physical: 1, length: 0, kind: UInt32(NB_EXT_DATA))]
    #expect(try YuzuNTFSDevice.overlappingMetadataSectors(cached, empty, sector: 512).isEmpty)
    #expect(try YuzuNTFSDevice.overlappingMetadataSectors(cached, huge, sector: 512) == cached)
    let overflow = [nb_extent(logical: 0, physical: UInt64.max, length: 512, kind: UInt32(NB_EXT_DATA))]
    #expect(throws: (any Error).self) { try YuzuNTFSDevice.overlappingMetadataSectors(cached, overflow, sector: 512) }
}

@Test func metadataPurgeSmallFileMicrobenchmark() throws {
    // Real production intersection used by map and completeIO. Metadata cache
    // grows with small-file creation; payload intersects only eight sectors.
    let cached = Set((0..<10000).map { Int64($0 * 512) })
    let extents = [nb_extent(logical: 0, physical: 512 * 5000, length: 4096, kind: UInt32(NB_EXT_DATA))]
    let start = DispatchTime.now().uptimeNanoseconds
    var matches = 0
    for _ in 0..<1000 {
        matches += try YuzuNTFSDevice.overlappingMetadataSectors(cached, extents, sector: 512).count
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    #expect(matches == 8000)
    print("METADATA_PURGE cached=10000 queries=1000 sectors=8 seconds=\(elapsed)")
}
