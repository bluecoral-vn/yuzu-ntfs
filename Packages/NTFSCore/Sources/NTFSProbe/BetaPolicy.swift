// SPDX-License-Identifier: GPL-2.0-only
import Foundation

public enum BetaPolicy {
    public static let group = "37PX6W22C5.com.bluecoral.vn.yuzuntfs"
    public static let acknowledgement = Data("acknowledged-v1\n".utf8)
    public static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Library/Application Support/YuzuNTFS", isDirectory: true)
    }
    public static func admits(serial: UInt64, acknowledgement: Data?, allowlist: String?, clean: Bool) -> Bool {
        clean && acknowledgement == Self.acknowledgement && WriteAllowlist.permits(serial: serial, contents: allowlist)
    }
    public static func acknowledged(at directory: URL?) -> Bool {
        guard let directory else { return false }
        return (try? Data(contentsOf: directory.appendingPathComponent("beta-ack"))) == acknowledgement
    }
    public static func recordAcknowledgement(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try acknowledgement.write(to: directory.appendingPathComponent("beta-ack"), options: .atomic)
    }
    public static func setAllowed(_ enabled: Bool, serial: UInt64, at directory: URL) throws {
        let url = directory.appendingPathComponent("write-serials.txt")
        let contents = FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
        let lines = contents.split(separator: "\n").map(String.init)
        guard lines.allSatisfy({ $0.utf8.count == 16 && $0.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }),
              !enabled || acknowledged(at: directory) else { throw CocoaError(.fileReadCorruptFile) }
        var serials = Set(lines.compactMap { UInt64($0, radix: 16) })
        if enabled { serials.insert(serial) } else { serials.remove(serial) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try serials.sorted().map { String(format: "%016llX\n", $0) }.joined().write(to: url, atomically: true, encoding: .utf8)
    }
}
