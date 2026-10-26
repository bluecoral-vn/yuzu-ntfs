// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import NTFSProbe

struct BetaPolicyTests {
    @Test func physicalReadOnlyPrecedesEveryPreferenceReason() {
        for acknowledged in [false, true] {
            for allowed in [false, true] {
                for requestedReadOnly in [false, true] {
                    for resourceWritable in [false, true] {
                        #expect(ReadOnlyReason.forCleanDevice(mediaWritable: false, resourceWritable: resourceWritable,
                            acknowledged: acknowledged, allowed: allowed, requestedReadOnly: requestedReadOnly) == .deviceReadOnly)
                    }
                }
            }
        }
    }
    @Test func ordinaryROResourceOnWritableMediaRetainsActionableReason() {
        #expect(ReadOnlyReason.forCleanDevice(mediaWritable: true, resourceWritable: false,
            acknowledged: false, allowed: false, requestedReadOnly: false) == .acknowledgementRequired)
        #expect(ReadOnlyReason.forCleanDevice(mediaWritable: true, resourceWritable: false,
            acknowledged: true, allowed: false, requestedReadOnly: false) == .notAllowed)
        let reason = ReadOnlyReason.forCleanDevice(mediaWritable: true, resourceWritable: false,
            acknowledged: true, allowed: true, requestedReadOnly: false)
        #expect(reason == .requestedReadOnly && reason.permitsWriteRemount)
    }
    @Test func unsafeReasonsNeverRequestWritableRemount() {
        for reason: ReadOnlyReason in [.deviceReadOnly, .hibernated, .fastStartup, .dirtyLog, .dirtyFlag, .bitlocker, .unsupported, .engineError] {
            #expect(!reason.permitsWriteRemount)
        }
        for reason: ReadOnlyReason in [.writable, .acknowledgementRequired, .notAllowed, .requestedReadOnly] {
            #expect(reason.permitsWriteRemount)
        }
    }
    @Test func admissionRequiresEveryGate() {
        let serial: UInt64 = 0x1234
        for ack in [false, true] {
            for listed in [false, true] {
                for clean in [false, true] {
                    #expect(BetaPolicy.admits(serial: serial, acknowledgement: ack ? Data("acknowledged-v1\n".utf8) : nil,
                        allowlist: listed ? "0000000000001234\n" : "", clean: clean) == (ack && listed && clean))
                }
            }
        }
        #expect(!BetaPolicy.admits(serial: serial, acknowledgement: Data("true".utf8), allowlist: "0000000000001234", clean: true))
        #expect(!BetaPolicy.admits(serial: serial, acknowledgement: Data("acknowledged-v1\n".utf8), allowlist: "0000000000001234\nbad", clean: true))
    }
    @Test func statusRoundTripAndMalformedRejection() throws {
        let identity = DiskIdentity(device: "disk4s1", volumeUUID: NTFSBootSector.volumeUUID(serial: 0x1234),
            mediaUUID: nil, appearedAt: Date(timeIntervalSinceReferenceDate: 1), fileSystem: "yuzuntfs", deviceWritable: true)
        let status = VolumeStatus(serial: 0x1234, identity: identity, writable: false, reason: .hibernated)
        #expect(try JSONDecoder().decode(VolumeStatus.self, from: JSONEncoder().encode(status)) == status)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(VolumeStatus.self, from: Data("{\"serial\":1}".utf8)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try status.write(at: root)
        #expect(try JSONDecoder().decode(VolumeStatus.self, from: Data(contentsOf: root.appendingPathComponent(status.fileName))) == status)
    }
    @Test func preferencesRequireAcknowledgementAndRejectSignedHex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) { try BetaPolicy.setAllowed(true, serial: 1, at: root) }
        try BetaPolicy.recordAcknowledgement(at: root)
        try BetaPolicy.setAllowed(true, serial: 1, at: root)
        try BetaPolicy.setAllowed(true, serial: 2, at: root)
        try BetaPolicy.setAllowed(false, serial: 1, at: root)
        #expect(try String(contentsOf: root.appendingPathComponent("write-serials.txt"), encoding: .utf8) == "0000000000000002\n")
        try "+000000000000001\n".write(to: root.appendingPathComponent("write-serials.txt"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try BetaPolicy.setAllowed(true, serial: 2, at: root) }
    }
    @Test func settingsMergeAndBackupsPreserveOthers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("enabledModules.plist")
        let original = try PropertyListSerialization.data(fromPropertyList: ["other.module"], format: .xml, options: 0)
        try original.write(to: url)
        let first = try ModuleSettings.setEnabled(true, at: url)
        #expect(try Data(contentsOf: first) == original)
        #expect(try ModuleSettings.entries(at: url) == ["other.module", ModuleSettings.identifier])
        let second = try ModuleSettings.setEnabled(false, at: url)
        #expect(first != second)
        #expect(try ModuleSettings.entries(at: url) == ["other.module"])
        try Data("invalid".utf8).write(to: url)
        #expect(throws: (any Error).self) { try ModuleSettings.setEnabled(true, at: url) }
        #expect(try Data(contentsOf: url) == Data("invalid".utf8))
    }
    @Test func activeMountGuardFailsClosed() throws {
        #expect(try ModuleSettings.hasActiveVolumes("/dev/disk1 on / (apfs, local)", home: "/Users/test") == false)
        #expect(try ModuleSettings.hasActiveVolumes("/dev/disk4 on /Volumes/Test (yuzuntfs, local, fskit)", home: "/Users/test"))
        #expect(try ModuleSettings.hasActiveVolumes("x on /Volumes/Test (nullfs, fskit)", home: "/Users/test"))
        #expect(throws: (any Error).self) { try ModuleSettings.hasActiveVolumes("unparseable", home: "/Users/test") }
    }
    @Test func remountConstructionSupportsVolumeDevicesAndRejectsInjection() throws {
        #expect(try RemountRequest(device: "disk4s1").devicePath == "/dev/disk4s1")
        #expect(try RemountRequest(device: "disk4").devicePath == "/dev/disk4")
        #expect(try RemountRequest(device: "disk4", allowWriting: true).mountOption == "rw")
        #expect(try RemountRequest(device: "disk4", allowWriting: false).mountOption == "rdonly")
        for input in ["/dev/disk4", "disk4;echo", "", "diskx", "disk4/../disk0"] {
            #expect(throws: (any Error).self) { try RemountRequest(device: input) }
        }
    }
}
