// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import NTFSProbe

private func fixtureSector(_ name: String) throws -> [UInt8] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("fixtures/\(name)")
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw NSError(domain: "Run scripts/make-fixtures.sh to generate missing fixture: \(name)", code: 1)
    }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: 4096)
    return Array(try #require(data))
}

private func parse(_ bytes: [UInt8]) throws -> NTFSBootSector {
    try bytes.withUnsafeBytes { try NTFSBootSector.parse($0) }
}

private func patch(_ bytes: [UInt8], offset: Int, value: UInt64, count: Int = 1) -> [UInt8] {
    var result = bytes
    for i in 0..<count { result[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    return result
}

@Test func parsesMkntfs512() throws {
    let bs = try parse(fixtureSector("basic-512.img"))
    #expect(bs.bytesPerSector == 512)
    #expect(bs.sectorsPerCluster == 8)
    #expect(bs.clusterSize == 4096)
    #expect(bs.mftRecordSize == 1024)
    #expect(bs.indexRecordSize == 4096)
    #expect(bs.totalSectors > 0)
    #expect(bs.mftLCN > 0)
    #expect(bs.mftMirrLCN > 0)
}
@Test func parses4Kn() throws {
    let bs = try parse(fixtureSector("4kn.img"))
    #expect(bs.bytesPerSector == 4096)
    #expect(bs.mftRecordSize == 4096)
}
@Test func parses64KClusters() throws { #expect(try parse(fixtureSector("c64k.img")).clusterSize == 65536) }
@Test func rejectsFAT() throws {
    var fatSector = [UInt8](repeating: 0, count: 512)
    fatSector.replaceSubrange(3..<11, with: Array("MSDOS5.0".utf8))
    fatSector[510] = 0x55; fatSector[511] = 0xaa
    #expect(throws: NTFSProbeError.notNTFS) { try parse(fatSector) }
}
@Test(arguments: [UInt16(513), 0, 8192]) func rejectsBadSectorSize(_ v: UInt16) throws {
    let bytes = try fixtureSector("basic-512.img")
    #expect(throws: NTFSProbeError.self) { try parse(patch(bytes, offset: 11, value: UInt64(v), count: 2)) }
}
@Test func rejectsClusterOver2MiB() throws {
    let bytes = try fixtureSector("basic-512.img")
    #expect(throws: NTFSProbeError.self) { try parse(patch(bytes, offset: 13, value: UInt64(UInt8(bitPattern: -22)))) }
}
@Test func parsesNegativeClusterShift() throws {
    let bytes = try fixtureSector("basic-512.img")
    let bs = try parse(patch(bytes, offset: 13, value: UInt64(UInt8(bitPattern: -12))))
    #expect(bs.clusterSize == 4096)
    #expect(bs.sectorsPerCluster == 8)
}
@Test(arguments: [0, 3, 0x81, 0xf3]) func rejectsInvalidClusterEncoding(_ v: UInt64) throws {
    let bytes = try fixtureSector("basic-512.img")
    #expect(throws: NTFSProbeError.self) { try parse(patch(bytes, offset: 13, value: v)) }
}
@Test func rejectsMissingSignature() throws {
    let bytes = try fixtureSector("basic-512.img")
    #expect(throws: NTFSProbeError.notNTFS) { try parse(patch(bytes, offset: 510, value: 0)) }
}
@Test(arguments: [0, 11, 511]) func rejectsShortBuffer(_ count: Int) {
    #expect(throws: NTFSProbeError.self) { try parse([UInt8](repeating: 0, count: count)) }
}
@Test(arguments: [UInt64(0), 0x80, 0xe0]) func rejectsInvalidRecordSize(_ v: UInt64) throws {
    let bytes = try fixtureSector("basic-512.img")
    for offset in [64, 68] {
        #expect(throws: NTFSProbeError.self) { try parse(patch(bytes, offset: offset, value: v)) }
    }
}
@Test func parsesPositiveRecordSize() throws {
    let bytes = try fixtureSector("basic-512.img")
    #expect(try parse(patch(bytes, offset: 64, value: 2)).mftRecordSize == 8192)
}
@Test func rejectsOutOfVolumeMFT() throws {
    let bytes = try fixtureSector("basic-512.img")
    for offset in [48, 56] {
        #expect(throws: NTFSProbeError.self) { try parse(patch(bytes, offset: offset, value: .max, count: 8)) }
    }
    #expect(throws: NTFSProbeError.self) { try parse(patch(bytes, offset: 40, value: 0, count: 8)) }
}
@Test func uuidStableAndSerialSpecific() throws {
    let bytes = try fixtureSector("basic-512.img")
    let first = try parse(bytes)
    #expect(first.volumeUUID == (try parse(bytes)).volumeUUID)
    let changed = try parse(patch(bytes, offset: 72, value: first.serial ^ 1, count: 8))
    #expect(first.volumeUUID != changed.volumeUUID)
    #expect(first.volumeUUID.uuidString.split(separator: "-")[2].first == "5")
}
@Test func parsesUnalignedBuffer() throws {
    let bytes = [UInt8(0)] + (try fixtureSector("basic-512.img"))
    let bs = try bytes.withUnsafeBytes { try NTFSBootSector.parse(UnsafeRawBufferPointer(rebasing: $0[1...])) }
    #expect(bs.bytesPerSector == 512)
}
