// SPDX-License-Identifier: GPL-2.0-only
import Foundation

public enum NTFSInventory {
    /// Partitionless FSKit media have an empty Content hint on macOS 27. Query
    /// those leaves' disk info too; do not traverse known APFS container volumes.
    public static func candidateDevices(in data: Data) throws -> [String] {
        guard let tree = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let roots = tree["AllDisksAndPartitions"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        var result: [String] = []
        func collect(_ nodes: [[String: Any]]) {
            for node in nodes {
                let content = (node["Content"] as? String ?? "").lowercased()
                if content.isEmpty || content.contains("ntfs") || content == "microsoft basic data" {
                    if let identifier = node["DeviceIdentifier"] as? String { result.append(identifier) }
                }
                if let partitions = node["Partitions"] as? [[String: Any]] { collect(partitions) }
            }
        }
        collect(roots)
        return result
    }
}
