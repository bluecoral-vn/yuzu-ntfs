// SPDX-License-Identifier: GPL-2.0-only
import Foundation

public enum ReadOnlyReason: String, Codable, Sendable {
    case writable, acknowledgementRequired, notAllowed, requestedReadOnly, deviceReadOnly
    case hibernated, fastStartup, dirtyLog, dirtyFlag, bitlocker, unsupported, engineError
    /// A saved opt-in is not permission to remount an unsafe/device-RO drive RW.
    public var permitsWriteRemount: Bool {
        switch self {
        case .writable, .acknowledgementRequired, .notAllowed, .requestedReadOnly: true
        case .deviceReadOnly, .hibernated, .fastStartup, .dirtyLog, .dirtyFlag, .bitlocker, .unsupported, .engineError: false
        }
    }
    public static func forCleanDevice(writable: Bool, acknowledged: Bool, allowed: Bool, requestedReadOnly: Bool) -> Self {
        if !writable { return .deviceReadOnly }
        if !acknowledged { return .acknowledgementRequired }
        if !allowed { return .notAllowed }
        if requestedReadOnly { return .requestedReadOnly }
        return .writable
    }
}

public struct VolumeStatus: Codable, Equatable, Sendable {
    public var serial: UInt64
    public var device: String
    public var writable: Bool
    public var reason: ReadOnlyReason
    public init(serial: UInt64, device: String, writable: Bool, reason: ReadOnlyReason) {
        self.serial = serial; self.device = device; self.writable = writable; self.reason = reason
    }
    public func write(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("status-\(device).json"), options: .atomic)
    }
}

public struct RemountRequest: Sendable {
    public let devicePath: String
    public let mountOption: String
    public init(device: String, allowWriting: Bool = false) throws {
        guard device.wholeMatch(of: /disk[0-9]+(s[0-9]+)*/) != nil else { throw POSIXError(.EINVAL) }
        devicePath = "/dev/" + device
        mountOption = allowWriting ? "rw" : "rdonly"
    }
}
