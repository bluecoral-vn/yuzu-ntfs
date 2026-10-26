// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import NTFSProbe

struct BitLockerTests {
    @Test func recognizesBitLockerWithoutTreatingItAsWritableNTFS() throws {
        var sector = Data(repeating: 0, count: 512)
        sector.replaceSubrange(3..<11, with: Data("-FVE-FS-".utf8))
        #expect(sector.withUnsafeBytes { NTFSBootSector.isBitLocker($0) })
        #expect(throws: NTFSProbeError.self) { try sector.withUnsafeBytes { try NTFSBootSector.parse($0) } }
        #expect(!Data(repeating: 0, count: 10).withUnsafeBytes { NTFSBootSector.isBitLocker($0) })
        sector[3] = 0
        #expect(!sector.withUnsafeBytes { NTFSBootSector.isBitLocker($0) })
    }
}
