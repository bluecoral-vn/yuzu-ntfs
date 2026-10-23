// SPDX-License-Identifier: GPL-2.0-only
import Foundation

public enum WriteAllowlist {
    public static let relativePath = "Library/Application Support/YuzuNTFS/p0-rw-serials.txt"
    public static var fileURL: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relativePath) }
    public static func permits(serial: UInt64, contents: String?) -> Bool {
        guard let contents else { return false }
        var found = false
        for line in contents.split(separator: "\n") {
            guard line.utf8.count == 16, line.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }), let value = UInt64(line, radix: 16) else { return false }
            found = found || value == serial
        }
        return found
    }
}
