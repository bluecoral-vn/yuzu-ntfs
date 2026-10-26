// SPDX-License-Identifier: GPL-2.0-only
import Foundation

public enum ReadOnlyReason: String, Codable, Sendable {
    case writable, acknowledgementRequired, notAllowed, requestedReadOnly, deviceReadOnly
    case hibernated, fastStartup, dirtyLog, dirtyFlag, bitlocker, unsupported, engineError
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
    public init(device: String) throws {
        guard device.wholeMatch(of: /disk[0-9]+(s[0-9]+)*/) != nil else { throw POSIXError(.EINVAL) }
        devicePath = "/dev/" + device
    }
}
