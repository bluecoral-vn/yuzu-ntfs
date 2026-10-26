// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import NTFSProbe

struct StatusIdentityTests {
    private let serial: UInt64 = 0x1234
    private let appearance = Date(timeIntervalSinceReferenceDate: 1000)
    private let media = UUID(uuidString: "E6700023-50AD-48A9-8296-9DC6BB91B191")!
    private func identity(kind: String = "yuzuntfs", serial: UInt64 = 0x1234,
                          media: UUID? = nil, appearance: Date? = nil) -> DiskIdentity {
        DiskIdentity(device: "disk9s1", volumeUUID: NTFSBootSector.volumeUUID(serial: serial),
            mediaUUID: media ?? self.media, appearedAt: appearance ?? self.appearance,
            fileSystem: kind, deviceWritable: true)
    }
    @Test func bsdReuseAndNonNTFSNeverAdoptPreviousStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = identity()
        let status = VolumeStatus(serial: serial, identity: current, writable: true, reason: .writable,
            updatedAt: appearance.addingTimeInterval(1))
        try status.write(at: root)
        #expect(VolumeStatus.read(for: current, at: root) == status)
        // Even a copied/forged UUID is not evidence that exFAT is NTFS.
        #expect(VolumeStatus.read(for: identity(kind: "exfat"), at: root) == nil)
        #expect(VolumeStatus.read(for: identity(serial: 0x9876), at: root) == nil)
        #expect(VolumeStatus.read(for: identity(media: UUID()), at: root) == nil)
        #expect(VolumeStatus.read(for: identity(appearance: appearance.addingTimeInterval(2)), at: root) == nil)
    }
    @Test func staleTimestampAndLegacyRecordsFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = identity()
        let status = VolumeStatus(serial: serial, identity: current, writable: true, reason: .writable,
            updatedAt: appearance.addingTimeInterval(-1))
        try status.write(at: root)
        #expect(VolumeStatus.read(for: current, at: root) == nil)
        let legacy = Data("{\"serial\":4660,\"device\":\"disk9s1\",\"writable\":true,\"reason\":\"writable\"}".utf8)
        try legacy.write(to: root.appendingPathComponent(status.fileName))
        #expect(VolumeStatus.read(for: current, at: root) == nil)
    }
    @Test func unloadRemovesOnlyItsOwnVolumeIncarnation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = VolumeStatus(serial: serial, identity: identity(), writable: true, reason: .writable,
            updatedAt: appearance.addingTimeInterval(1))
        try old.write(at: root)
        let replacement = VolumeStatus(serial: serial, identity: identity(appearance: appearance.addingTimeInterval(2)),
            writable: false, reason: .notAllowed, updatedAt: appearance.addingTimeInterval(3))
        try replacement.write(at: root)
        try old.remove(at: root)
        #expect(VolumeStatus.read(for: identity(appearance: appearance.addingTimeInterval(2)), at: root) == replacement)
        try replacement.remove(at: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(replacement.fileName).path))
    }
    @Test func liveIdentityRequiresUUIDAndRejectsAppearanceReuse() {
        let current = identity()
        #expect(current.sameAttachment(as: current))
        #expect(!current.sameAttachment(as: identity(media: UUID())))
        #expect(!current.sameAttachment(as: identity(appearance: appearance.addingTimeInterval(1))))
        let incomplete = DiskIdentity(device: "disk9s1", volumeUUID: nil, mediaUUID: nil,
            appearedAt: appearance, fileSystem: "yuzuntfs", deviceWritable: true)
        let status = VolumeStatus(serial: serial, identity: current, writable: true, reason: .writable,
            updatedAt: appearance.addingTimeInterval(1))
        #expect(!status.matches(incomplete))
    }
}
