// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import NTFSProbe

struct RejectionTests {
    private let appearance = Date(timeIntervalSinceReferenceDate: 2000)
    private let media = UUID(uuidString: "0F2A1C6E-53A1-4E5C-8D2A-3A7C4B6E9F10")!
    private func identity(kind: String = "", media: UUID? = nil, appearance: Date? = nil) -> DiskIdentity {
        DiskIdentity(device: "disk9s1", volumeUUID: nil, mediaUUID: media ?? self.media,
                     appearedAt: appearance ?? self.appearance, fileSystem: kind, deviceWritable: true)
    }
    private func bitLockerSector() -> Data {
        var sector = Data(repeating: 0, count: 512)
        sector.replaceSubrange(3..<11, with: Data("-FVE-FS-".utf8))
        sector[510] = 0x55; sector[511] = 0xaa
        return sector
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func probeClassifiesSynthesizedBitLockerSectorAsRejection() {
        #expect(bitLockerSector().withUnsafeBytes { VolumeRejection.Kind.classify(bootSector: $0) } == .bitlocker)
        var ntfs = Data(repeating: 0, count: 512)
        ntfs.replaceSubrange(3..<11, with: Data("NTFS    ".utf8))
        #expect(ntfs.withUnsafeBytes { VolumeRejection.Kind.classify(bootSector: $0) } == nil)
    }
    @Test func rejectionIsAttachmentBoundAndNeverWritable() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rejection = try #require(VolumeRejection(kind: .bitlocker, identity: identity(), updatedAt: appearance.addingTimeInterval(1)))
        try rejection.write(at: root)
        #expect(VolumeRejection.read(for: identity(), at: root) == rejection)
        #expect(!rejection.reason.permitsWriteRemount && rejection.reason == .bitlocker)
        #expect(VolumeRejection.read(for: identity(media: UUID()), at: root) == nil)
        #expect(VolumeRejection.read(for: identity(appearance: appearance.addingTimeInterval(5)), at: root) == nil)
        #expect(VolumeRejection(kind: .bitlocker, identity: DiskIdentity(device: "disk9s1", volumeUUID: nil, mediaUUID: nil,
            appearedAt: appearance, fileSystem: "", deviceWritable: true)) == nil)
        let stale = try #require(VolumeRejection(kind: .bitlocker, identity: identity(), updatedAt: appearance.addingTimeInterval(-1)))
        try stale.write(at: root)
        #expect(VolumeRejection.read(for: identity(), at: root) == nil)
    }
    @Test func inventoryShowsRejectionButNeverAsNTFSIdentity() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rejected = try #require(VolumeRejection(kind: .bitlocker, identity: identity(), updatedAt: appearance.addingTimeInterval(1)))
        try rejected.write(at: root)
        guard case .rejected(let found) = DriveClassification.classify(identity: identity(), content: "microsoft basic data", directory: root) else {
            Issue.record("BitLocker rejection not shown"); return
        }
        #expect(found == rejected)
        // A rejection never produces NTFS status or controls, even if a forged NTFS record exists.
        #expect(VolumeStatus.read(for: identity(), at: root) == nil)
        // An actual NTFS personality on the same BSD name never adopts a rejection record.
        #expect(DriveClassification.classify(identity: identity(kind: "yuzuntfs"), content: "", directory: root) == .ntfs)
        // A non-NTFS filesystem with a leftover rejection, or no record, is ignored.
        #expect(DriveClassification.classify(identity: identity(kind: "exfat"), content: "microsoft basic data", directory: root) == .ignored)
        #expect(DriveClassification.classify(identity: identity(media: UUID()), content: "microsoft basic data", directory: root) == .ignored)
        #expect(DriveClassification.classify(identity: identity(), content: "windows_ntfs", directory: directory()) == .ntfs)
    }
}
