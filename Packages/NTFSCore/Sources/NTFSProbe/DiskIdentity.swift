// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import DiskArbitration

/// Identity of one attachment, not merely a reusable BSD device name.
public struct DiskIdentity: Hashable, Sendable {
    public let device: String
    public let volumeUUID: UUID?
    public let mediaUUID: UUID?
    public let appearedAt: Date
    public let fileSystem: String
    public let deviceWritable: Bool

    public init(device: String, volumeUUID: UUID?, mediaUUID: UUID?, appearedAt: Date,
                fileSystem: String, deviceWritable: Bool) {
        self.device = device; self.volumeUUID = volumeUUID; self.mediaUUID = mediaUUID
        self.appearedAt = appearedAt; self.fileSystem = fileSystem.lowercased(); self.deviceWritable = deviceWritable
    }
    public var isNTFS: Bool { fileSystem == "ntfs" || fileSystem == "yuzuntfs" }
    public func sameAttachment(as other: Self) -> Bool {
        device == other.device && volumeUUID == other.volumeUUID && mediaUUID == other.mediaUUID && appearedAt == other.appearedAt
    }

    public static func read(device: String, session: DASession? = nil) -> Self? {
        guard (try? RemountRequest(device: device)) != nil,
              let session = session ?? DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, device),
              let values = DADiskCopyDescription(disk) as? [String: Any],
              let appeared = values["DAAppearanceTime"] as? NSNumber,
              appeared.doubleValue.isFinite, appeared.doubleValue > 0,
              let writable = values[kDADiskDescriptionMediaWritableKey as String] as? Bool else { return nil }
        // This is server-supplied metadata from public DADiskCopyDescription.
        // Never substitute observation time: a late observer must still reject
        // status older than the actual attachment. Missing metadata fails closed.
        return Self(device: device, volumeUUID: uuid(values[kDADiskDescriptionVolumeUUIDKey as String]),
            mediaUUID: uuid(values[kDADiskDescriptionMediaUUIDKey as String]),
            appearedAt: Date(timeIntervalSinceReferenceDate: appeared.doubleValue),
            fileSystem: values[kDADiskDescriptionVolumeKindKey as String] as? String ?? "", deviceWritable: writable)
    }
    private static func uuid(_ value: Any?) -> UUID? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
        let uuid = value as! CFUUID
        let bytes = CFUUIDGetUUIDBytes(uuid)
        return UUID(uuid: (bytes.byte0, bytes.byte1, bytes.byte2, bytes.byte3, bytes.byte4, bytes.byte5, bytes.byte6, bytes.byte7,
                           bytes.byte8, bytes.byte9, bytes.byte10, bytes.byte11, bytes.byte12, bytes.byte13, bytes.byte14, bytes.byte15))
    }
}
