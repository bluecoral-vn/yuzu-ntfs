// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import FSKit
import Foundation
import NTFSProbe
import Observation
import OSLog
import UserNotifications

struct TrialDrive: Identifiable {
    var id: String
    var name: String
    var mount: String?
    var size: Int64
    var free: Int64
    var status: VolumeStatus?
    var writable: Bool
}

@MainActor @Observable final class TrialModel {
    var drives: [TrialDrive] = []
    var enabled = false
    var acknowledged = false
    var busy = false
    var message: String?
    var selectedReason: ReadOnlyReason?
    private let operations = DriveOperations()
    private var refreshing = false
    private var monitor: Task<Void, Never>?
    func start() {
        guard monitor == nil else { return }
        let qa = TrialQA(arguments: ProcessInfo.processInfo.arguments)
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                await qa?.consume(model: self)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    private var notified = Set<String>()
    private let logger = Logger(subsystem: "com.bluecoral.vn.yuzuntfs", category: "App")
    var directory: URL? { BetaPolicy.directory }
    func refresh() async {
        guard !refreshing else { return }; refreshing = true
        defer { refreshing = false }
        acknowledged = BetaPolicy.acknowledged(at: directory)
        do {
            let extensions = try await FSClient.shared.installedExtensions
            enabled = extensions.contains { $0.bundleIdentifier == ModuleSettings.identifier && $0.isEnabled }
            let mounts = try await SystemOperations.run("/sbin/mount", [])
            let mountLines = String(decoding: mounts.data, as: UTF8.self).components(separatedBy: "\n")
            let list = try await SystemOperations.run("/usr/sbin/diskutil", ["list", "-plist"])
            let candidates = try NTFSInventory.candidateDevices(in: list.data)
            var result: [TrialDrive] = []
            for id in candidates {
                let info = try await SystemOperations.run("/usr/sbin/diskutil", ["info", "-plist", id])
                guard let values = try PropertyListSerialization.propertyList(from: info.data, format: nil) as? [String: Any] else { continue }
                let kind = (values["FilesystemType"] as? String ?? "").lowercased()
                let content = (values["Content"] as? String ?? "").lowercased()
                let status = directory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("status-\(id).json")) }.flatMap { try? JSONDecoder().decode(VolumeStatus.self, from: $0) }
                guard kind.contains("ntfs") || content.contains("ntfs") || status != nil else { continue }
                let mount = values["MountPoint"] as? String
                let actualYuzuRW = mountLines.contains { $0.hasPrefix("/dev/\(id) on ") && $0.contains("(yuzuntfs,") && !$0.contains("read-only") }
                let writable = mount != nil && actualYuzuRW && status?.writable == true
                result.append(TrialDrive(id: id, name: values["VolumeName"] as? String ?? values["MediaName"] as? String ?? id, mount: mount,
                    size: (values["TotalSize"] as? NSNumber)?.int64Value ?? 0, free: ((values["FreeSpace"] ?? values["VolumeFreeSpace"]) as? NSNumber)?.int64Value ?? 0, status: status, writable: writable))
                if let reason = status?.reason, Self.unsafe(reason), !notified.contains(id) {
                    notified.insert(id)
                    let content = UNMutableNotificationContent(); content.title = String(localized: "Drive is read-only")
                    content.body = Self.explanation(reason)
                    try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                }
            }
            drives = result
            notified.formIntersection(Set(result.map(\.id)))
        } catch { logger.error("Status refresh: \(error.localizedDescription)") }
    }
    func execute(_ operation: () async throws -> Void) async {
        guard !busy else { return }; busy = true; message = nil
        defer { busy = false }
        do { try await operation() } catch { message = error.localizedDescription; logger.error("Action: \(error.localizedDescription)") }
        await refresh()
    }
    func acknowledge() async {
        await execute {
            guard let directory else { throw CocoaError(.fileNoSuchFile) }
            try BetaPolicy.recordAcknowledgement(at: directory)
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) }
        }
    }
    func setEnabled(_ value: Bool) async {
        await execute {
            try await SystemOperations.setEnabled(value)
            let deadline = ContinuousClock.now + .seconds(30)
            var lastError: (any Error)?
            while ContinuousClock.now < deadline {
                do {
                    let installed = try await FSClient.shared.installedExtensions
                    let actual = installed.contains { $0.bundleIdentifier == ModuleSettings.identifier && $0.isEnabled }
                    if actual == value { return }
                } catch { lastError = error }
                try await Task.sleep(for: .seconds(1))
            }
            throw lastError ?? POSIXError(.ETIMEDOUT)
        }
    }
    func isAllowed(_ drive: TrialDrive) -> Bool {
        guard let serial = drive.status?.serial, let directory else { return false }
        return WriteAllowlist.permits(serial: serial, contents: try? String(contentsOf: directory.appendingPathComponent("write-serials.txt"), encoding: .utf8))
    }
    func setWriting(_ value: Bool, drive: TrialDrive) async {
        await execute {
            guard let directory, let status = drive.status, let operations else { throw POSIXError(.ENODEV) }
            guard !value || acknowledged else { throw POSIXError(.EPERM) }
            try BetaPolicy.setAllowed(value, serial: status.serial, at: directory)
            // A failed/busy unmount never force-unmounts. The preference remains for the next clean mount.
            try await operations.perform(device: drive.id, action: "remount", allowWriting: value)
        }
    }
    func eject(_ drive: TrialDrive) async { await execute { try await operations?.perform(device: drive.id, action: "eject") } }
    func open(_ drive: TrialDrive) { if let mount = drive.mount { NSWorkspace.shared.open(URL(fileURLWithPath: mount)) } }
    func openSettings() {
        if #available(macOS 27.0, *) { FSClient.shared.openFileSystemExtensionsSettings() }
        else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
    }
    static func unsafe(_ reason: ReadOnlyReason) -> Bool {
        [.hibernated, .fastStartup, .dirtyLog, .dirtyFlag, .bitlocker, .unsupported, .engineError].contains(reason)
    }
    static func explanation(_ reason: ReadOnlyReason) -> String {
        switch reason {
        case .writable: String(localized: "Writing allowed (beta). Keep backups and eject before unplugging.")
        case .acknowledgementRequired: String(localized: "Accept the beta backup acknowledgement before allowing writing.")
        case .notAllowed: String(localized: "Writing is off for this drive. Enable Allow writing (beta) to opt in.")
        case .requestedReadOnly: String(localized: "This drive was explicitly mounted read-only. Eject and reconnect it to apply your preference.")
        case .deviceReadOnly: String(localized: "The device is write-protected. Check its physical lock or image permissions.")
        case .hibernated, .fastStartup: String(localized: "Windows left this drive hibernated or in Fast Startup. In Windows, shut down while holding Shift, or turn off Fast Startup. Never delete hiberfil.sys to force writing.")
        case .dirtyLog, .dirtyFlag: String(localized: "Windows marked this drive dirty. In Windows, run chkdsk /f on this drive, then safely eject it. Yuzu never repairs or clears the flag automatically.")
        case .bitlocker: String(localized: "BitLocker encryption is unsupported. Unlock and decrypt the drive in Windows; Yuzu cannot mount it.")
        case .unsupported: String(localized: "This NTFS format is unsupported. Use Windows to inspect the drive; there is no write override.")
        case .engineError: String(localized: "A filesystem error stopped new writes. Eject the drive and check it with chkdsk in Windows. Already-mapped data can still change until eject (beta limitation M-R1).")
        }
    }
    func exportDiagnostics() async {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "YuzuNTFS-diagnostics.zip"; panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        await execute {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let logs = try await SystemOperations.run("/usr/bin/log", ["show", "--last", "15m", "--style", "compact", "--predicate", "subsystem BEGINSWITH 'com.bluecoral.vn.yuzuntfs'"])
            try logs.data.write(to: temp.appendingPathComponent("unified-log.txt"))
            let summary = "Yuzu NTFS 0.1.0 Beta (2)\n\(ProcessInfo.processInfo.operatingSystemVersionString)\nEnabled: \(enabled)\n" + drives.map { "\($0.id) \($0.writable ? "RW" : "RO") \($0.status?.reason.rawValue ?? "unknown")" }.joined(separator: "\n")
            try summary.write(to: temp.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
            _ = try await SystemOperations.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", temp.path, destination.path])
        }
    }
}
