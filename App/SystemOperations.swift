// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import DiskArbitration
import NTFSProbe

struct CommandOutput: Sendable { let data: Data; let status: Int32 }
enum SystemOperations {
    static func run(_ path: String, _ arguments: [String]) async throws -> CommandOutput {
        try await Task.detached {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
            process.standardOutput = output; process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let error = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "YuzuNTFS", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)])
            }
            return CommandOutput(data: data, status: process.terminationStatus)
        }.value
    }
    static func requireNoActiveVolumes() async throws {
        let inventory = try await run("/sbin/mount", [])
        guard try !ModuleSettings.hasActiveVolumes(String(decoding: inventory.data, as: UTF8.self), home: NSHomeDirectory()) else {
            throw NSError(domain: "YuzuNTFS", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Eject all FSKit drives before enabling or disabling Yuzu NTFS.")])
        }
    }
    static func setEnabled(_ enabled: Bool) async throws {
        try await requireNoActiveVolumes()
        if enabled {
            _ = try await run("/usr/bin/pluginkit", ["-e", "use", "-i", ModuleSettings.identifier])
        }
        try ModuleSettings.setEnabled(enabled, at: ModuleSettings.url)
        try await requireNoActiveVolumes()
        let result: CommandOutput
        do { result = try await run("/usr/bin/pgrep", ["-u", String(getuid()), "-x", "fskit_agent"]) }
        catch let error as NSError where error.code == 1 { return }
        for text in String(decoding: result.data, as: UTF8.self).split(whereSeparator: \.isWhitespace) {
            guard let pid = Int32(text), pid > 1 else { throw POSIXError(.EINVAL) }
            let identity = try await run("/bin/ps", ["-p", String(pid), "-o", "uid=,comm="])
            let parts = String(decoding: identity.data, as: UTF8.self).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, parts[0] == String(getuid()), URL(fileURLWithPath: String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent == "fskit_agent" else { throw POSIXError(.EPERM) }
            try await requireNoActiveVolumes()
            guard kill(pid, SIGKILL) == 0 else { throw POSIXError(.EPERM) }
        }
    }
}

private final class DiskOperation: @unchecked Sendable {
    let continuation: CheckedContinuation<Void, any Error>
    init(_ continuation: CheckedContinuation<Void, any Error>) { self.continuation = continuation }
}
private func diskReply(_ disk: DADisk, _ dissenter: DADissenter?, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let operation = Unmanaged<DiskOperation>.fromOpaque(context).takeRetainedValue()
    if let dissenter {
        let status = DADissenterGetStatus(dissenter)
        let reason = (DADissenterGetStatusString(dissenter) as String?)
            ?? (status > 0 && status <= ELAST
                ? String(cString: strerror(status))
                : NSError(domain: NSMachErrorDomain, code: Int(status)).localizedDescription)
        let description = "\(reason) (Disk Arbitration \(String(format: "0x%08X", status)))."
        operation.continuation.resume(throwing: NSError(domain: "DiskArbitration", code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: description]))
    } else { operation.continuation.resume() }
}

@MainActor final class DriveOperations {
    private let session: DASession
    init?() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        self.session = session
        DASessionSetDispatchQueue(session, .main)
    }
    func identity(device: String) -> DiskIdentity? { DiskIdentity.read(device: device, session: session) }
    private func requireIdentity(_ expected: DiskIdentity, remount: Bool, allowWriting: Bool) throws {
        guard let current = identity(device: expected.device), current.sameAttachment(as: expected) else { throw POSIXError(.ENODEV) }
        if remount && !current.isNTFS { throw POSIXError(.EINVAL) }
        if allowWriting && !current.deviceWritable { throw POSIXError(.EROFS) }
    }
    func perform(identity: DiskIdentity, action: String, allowWriting: Bool = false) async throws {
        try requireIdentity(identity, remount: action == "remount", allowWriting: allowWriting)
        let request = try RemountRequest(device: identity.device, allowWriting: allowWriting)
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, request.devicePath) else { throw POSIXError(.ENODEV) }
        if action == "remount" || action == "eject" {
            try await withCheckedThrowingContinuation { continuation in
                let context = Unmanaged.passRetained(DiskOperation(continuation)).toOpaque()
                DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), diskReply, context)
            }
        }
        // Re-check after the asynchronous unmount as BSD names can be reused.
        try requireIdentity(identity, remount: action == "remount", allowWriting: allowWriting)
        if action == "remount" {
            try await withCheckedThrowingContinuation { continuation in
                let context = Unmanaged.passRetained(DiskOperation(continuation)).toOpaque()
                let option = request.mountOption as CFString
                var arguments: [Unmanaged<CFString>?] = [.passUnretained(option), nil]
                withExtendedLifetime(option) {
                    arguments.withUnsafeMutableBufferPointer {
                        DADiskMountWithArguments(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), diskReply, context, $0.baseAddress)
                    }
                }
            }
        } else if action == "eject" {
            // Eject the containing media, not just an NTFS partition.
            let media = DADiskCopyWholeDisk(disk) ?? disk
            try await withCheckedThrowingContinuation { continuation in
                let context = Unmanaged.passRetained(DiskOperation(continuation)).toOpaque()
                DADiskEject(media, DADiskEjectOptions(kDADiskEjectOptionDefault), diskReply, context)
            }
        }
    }
}
