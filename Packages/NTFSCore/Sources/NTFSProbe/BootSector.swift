// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit

public enum NTFSProbeError: Error, Equatable, Sendable {
    case notNTFS
    case invalidGeometry(String)
}

public struct NTFSBootSector: Sendable {
    public let bytesPerSector: UInt32
    public let sectorsPerCluster: UInt32
    public let clusterSize: UInt32
    public let totalSectors: UInt64
    public let mftLCN: UInt64
    public let mftMirrLCN: UInt64
    public let mftRecordSize: UInt32
    public let indexRecordSize: UInt32
    public let serial: UInt64
    public static func isBitLocker(_ bytes: UnsafeRawBufferPointer) -> Bool {
        bytes.count >= 11 && bytes[3] == 0x2d && bytes[4] == 0x46 && bytes[5] == 0x56
            && bytes[6] == 0x45 && bytes[7] == 0x2d && bytes[8] == 0x46 && bytes[9] == 0x53 && bytes[10] == 0x2d
    }

    public static func parse(_ bytes: UnsafeRawBufferPointer) throws(NTFSProbeError) -> NTFSBootSector {
        guard bytes.count >= 512 else { throw .invalidGeometry("Boot sector shorter than 512 bytes") }
        guard bytes[3] == 0x4e, bytes[4] == 0x54, bytes[5] == 0x46, bytes[6] == 0x53,
              bytes[7] == 0x20, bytes[8] == 0x20, bytes[9] == 0x20, bytes[10] == 0x20,
              bytes[510] == 0x55, bytes[511] == 0xaa else { throw .notNTFS }
        // Byte-wise little-endian loads also support unaligned buffers.
        func littleEndian(_ offset: Int, _ count: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<count { value |= UInt64(bytes[offset + index]) << (8 * index) }
            return value
        }
        let bps = UInt32(littleEndian(11, 2))
        guard [512, 1024, 2048, 4096].contains(bps) else {
            throw .invalidGeometry("Sector size must be a power of two from 512 through 4096")
        }
        let encodedCluster = Int8(bitPattern: bytes[13])
        let cluster: UInt32
        if bytes[13] < 0xf4 {
            let sectors = UInt32(bytes[13])
            guard sectors > 0, sectors.nonzeroBitCount == 1 else { throw .invalidGeometry("Invalid sectors per cluster") }
            cluster = bps * sectors
        } else {
            // NTFS extended encoding denotes sector counts 2^12...2^1, not byte sizes.
            guard encodedCluster >= -12, encodedCluster < 0 else {
                throw .invalidGeometry("Invalid signed cluster-size encoding")
            }
            let sectors = UInt32(1) << UInt32(-Int(encodedCluster))
            cluster = sectors * bps
        }
        guard cluster >= bps, cluster <= 2 * 1024 * 1024, cluster % bps == 0 else {
            throw .invalidGeometry("Cluster size outside supported sector-aligned range")
        }
        let total = littleEndian(40, 8)
        let mft = littleEndian(48, 8)
        let mirror = littleEndian(56, 8)
        let clusterCount = total / UInt64(cluster / bps)
        guard clusterCount > 0, mft < clusterCount, mirror < clusterCount else {
            throw .invalidGeometry("Empty volume or MFT location outside volume")
        }
        func recordSize(_ offset: Int) throws(NTFSProbeError) -> UInt32 {
            let encoded = Int8(bitPattern: bytes[offset])
            let size: UInt64
            if encoded > 0 {
                size = UInt64(encoded) * UInt64(cluster)
            } else {
                guard encoded >= -31, encoded < 0 else { throw .invalidGeometry("Invalid record-size exponent") }
                size = UInt64(1) << UInt64(-Int(encoded))
            }
            guard size >= UInt64(bps), size <= UInt64(UInt32.max), size.nonzeroBitCount == 1 else {
                throw .invalidGeometry("Invalid record size")
            }
            return UInt32(size)
        }
        return try NTFSBootSector(bytesPerSector: bps, sectorsPerCluster: cluster / bps,
                                  clusterSize: cluster, totalSectors: total, mftLCN: mft,
                                  mftMirrLCN: mirror, mftRecordSize: recordSize(64),
                                  indexRecordSize: recordSize(68), serial: littleEndian(72, 8))
    }

    public var volumeUUID: UUID {
        // RFC 9562 UUIDv5: fixed project namespace 92F6726A-7F30-579F-9B24-DACE3D692866
        // followed by the NTFS 64-bit serial in little-endian order (no text encoding).
        var input: [UInt8] = [0x92, 0xf6, 0x72, 0x6a, 0x7f, 0x30, 0x57, 0x9f,
                              0x9b, 0x24, 0xda, 0xce, 0x3d, 0x69, 0x28, 0x66]
        for index in 0..<8 { input.append(UInt8(truncatingIfNeeded: serial >> (8 * index))) }
        var digest = Array(Insecure.SHA1.hash(data: input).prefix(16))
        digest[6] = (digest[6] & 0x0f) | 0x50
        digest[8] = (digest[8] & 0x3f) | 0x80
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5],
                           digest[6], digest[7], digest[8], digest[9], digest[10], digest[11],
                           digest[12], digest[13], digest[14], digest[15]))
    }
}
