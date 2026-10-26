// SPDX-License-Identifier: GPL-2.0-only
import Foundation

public enum ModuleSettings {
    public static let identifier = "com.bluecoral.vn.yuzuntfs.fsmodule"
    public static var url: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist") }
    public static func entries(at url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let entries = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String] else { throw CocoaError(.fileReadCorruptFile) }
        return entries
    }
    @discardableResult public static func setEnabled(_ enabled: Bool, at url: URL) throws -> URL {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let before = exists ? try Data(contentsOf: url) : try PropertyListSerialization.data(fromPropertyList: [String](), format: .xml, options: 0)
        guard let original = try PropertyListSerialization.propertyList(from: before, format: nil) as? [String] else { throw CocoaError(.fileReadCorruptFile) }
        var updated = original.filter { $0 != identifier }
        if enabled { updated.append(identifier) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.appendingPathExtension("yuzu-\(Int64(Date().timeIntervalSince1970 * 1_000_000))-\(UUID().uuidString).backup")
        try before.write(to: backup, options: .withoutOverwriting)
        let unchanged = exists ? try Data(contentsOf: url) == before : !FileManager.default.fileExists(atPath: url.path)
        guard unchanged else { throw CocoaError(.fileWriteFileExists) }
        if updated != original || !exists {
            try PropertyListSerialization.data(fromPropertyList: updated, format: .xml, options: 0).write(to: url, options: .atomic)
        }
        return backup
    }
    public static func hasActiveVolumes(_ inventory: String, home: String) throws -> Bool {
        let native: Set<String> = ["apfs", "hfs", "nullfs", "devfs", "autofs", "nfs", "smbfs", "webdav", "udf", "cd9660", "msdos", "exfat"]
        var coreDeviceSeen = false
        for line in inventory.split(separator: "\n") {
            guard let on = line.range(of: " on "), let optionsStart = line.range(of: " (", options: .backwards), line.hasSuffix(")") else { throw CocoaError(.fileReadCorruptFile) }
            let source = String(line[..<on.lowerBound])
            let mount = String(line[on.upperBound..<optionsStart.lowerBound])
            let options = line[optionsStart.upperBound..<line.index(before: line.endIndex)].components(separatedBy: ", ")
            let kind = options[0]
            let coreSource = "devices -- " + URL(fileURLWithPath: home).appendingPathComponent("Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data").absoluteString + "/"
            if kind == "devicefs", source == coreSource, mount == home + "/Library/Developer/CoreDevice/DeviceFS", !coreDeviceSeen { coreDeviceSeen = true; continue }
            if !native.contains(kind.lowercased()) || options.contains("fskit") { return true }
        }
        return false
    }
}
