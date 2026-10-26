// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// A probe-time refusal for one disk attachment. It never carries an NTFS
/// serial/volume identity and never grants writing; it only explains why the
/// volume was not mounted.
public struct VolumeRejection: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case bitlocker, unsupported
        public static func classify(bootSector: UnsafeRawBufferPointer) -> Self? {
            NTFSBootSector.isBitLocker(bootSector) ? .bitlocker : nil
        }
    }
    public let kind: Kind
    public let device: String
    public let mediaUUID: UUID
    public let appearedAt: Date
    public let updatedAt: Date
    public var reason: ReadOnlyReason { kind == .bitlocker ? .bitlocker : .unsupported }

    /// Requires a stable media UUID: BSD name + appearance alone is not attachment identity.
    public init?(kind: Kind, identity: DiskIdentity, updatedAt: Date = Date()) {
        guard let media = identity.mediaUUID else { return nil }
        self.kind = kind; device = identity.device; mediaUUID = media
        appearedAt = identity.appearedAt; self.updatedAt = updatedAt
    }
    private static func fileName(device: String) -> String { "rejection-\(device).json" }
    public func matches(_ identity: DiskIdentity) -> Bool {
        !identity.isNTFS && device == identity.device && mediaUUID == identity.mediaUUID
            && appearedAt == identity.appearedAt && updatedAt >= identity.appearedAt
    }
    public static func read(for identity: DiskIdentity, at directory: URL?) -> Self? {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent(fileName(device: identity.device))),
              let record = try? JSONDecoder().decode(Self.self, from: data), record.matches(identity) else { return nil }
        return record
    }
    public func write(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent(Self.fileName(device: device)), options: .atomic)
    }
}

public enum DriveClassification: Equatable, Sendable {
    case ntfs, rejected(VolumeRejection), ignored

    /// NTFS identity comes only from the live DA personality (or an unformatted
    /// Windows_NTFS content hint without a rejection). Rejections are shown read-only.
    public static func classify(identity: DiskIdentity, content: String, directory: URL?) -> Self {
        if identity.isNTFS { return .ntfs }
        guard identity.fileSystem.isEmpty else { return .ignored }
        if let rejection = VolumeRejection.read(for: identity, at: directory) { return .rejected(rejection) }
        return content.lowercased() == "windows_ntfs" ? .ntfs : .ignored
    }
}
