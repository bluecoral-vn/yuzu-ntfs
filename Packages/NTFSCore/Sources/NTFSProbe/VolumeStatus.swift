// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Darwin

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
    public let publisherID: UUID
    public let mediaUUID: UUID?
    public let appearedAt: Date
    public var updatedAt: Date
    public var volumeUUID: UUID { NTFSBootSector.volumeUUID(serial: serial) }
    public var fileName: String { Self.fileName(device: device, volumeUUID: volumeUUID) }
    public var writable: Bool
    public var reason: ReadOnlyReason
    public init(serial: UInt64, identity: DiskIdentity, writable: Bool, reason: ReadOnlyReason, updatedAt: Date = Date()) {
        self.serial = serial; device = identity.device; mediaUUID = identity.mediaUUID
        publisherID = UUID()
        appearedAt = identity.appearedAt; self.updatedAt = updatedAt; self.writable = writable; self.reason = reason
    }
    private static func fileName(device: String, volumeUUID: UUID) -> String {
        "status-\(device)-\(volumeUUID.uuidString).json"
    }
    public func matches(_ identity: DiskIdentity) -> Bool {
        identity.isNTFS && device == identity.device && volumeUUID == identity.volumeUUID
            && mediaUUID == identity.mediaUUID && appearedAt == identity.appearedAt && updatedAt >= identity.appearedAt
    }
    public static func read(for identity: DiskIdentity, at directory: URL?) -> Self? {
        guard identity.isNTFS, let directory, let uuid = identity.volumeUUID,
              let data = try? Data(contentsOf: directory.appendingPathComponent(fileName(device: identity.device, volumeUUID: uuid))),
              let status = try? JSONDecoder().decode(Self.self, from: data), status.matches(identity) else { return nil }
        return status
    }
    public func remove(at directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try withStatusLock(at: directory) {
            let url = directory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let current = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard current.publisherID == publisherID, current.device == device, current.serial == serial,
                  current.mediaUUID == mediaUUID, current.appearedAt == appearedAt else { return }
            try FileManager.default.removeItem(at: url)
        }
    }
    public func write(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try withStatusLock(at: directory) {
            try JSONEncoder().encode(self).write(to: directory.appendingPathComponent(fileName), options: .atomic)
        }
    }
    private func withStatusLock<T>(at directory: URL, _ body: () throws -> T) throws -> T {
        // Keep the lock inode stable: unlinking it could split concurrent writers.
        let lock = directory.appendingPathComponent(".\(fileName).lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
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
