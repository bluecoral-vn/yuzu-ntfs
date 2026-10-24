// SPDX-License-Identifier: GPL-2.0-only
// Throwaway R1 spike: not part of either shipping target.
import Foundation
import FSKit

if CommandLine.arguments.contains("--open-settings") {
    if #available(macOS 27.0, *) {
        print("openFileSystemExtensionsSettings=\(FSClient.shared.openFileSystemExtensionsSettings())")
    } else {
        print("openFileSystemExtensionsSettings unavailable before macOS 27")
        exit(2)
    }
}

do {
    let modules = try await FSClient.shared.installedExtensions
    let yuzu = modules.filter { $0.bundleIdentifier == "com.bluecoral.vn.yuzuntfs.fsmodule" }
    let arguments = CommandLine.arguments
    let disabled = arguments.contains("--expect-disabled")
    let pathIndex = arguments.firstIndex(of: "--expect-path")
    if let pathIndex, pathIndex + 1 >= arguments.count { print("--expect-path requires a URL path"); exit(2) }
    let expectedPath = pathIndex.map { arguments[$0 + 1] }
    for module in modules {
        print("\(module.bundleIdentifier) enabled=\(module.isEnabled) url=\(module.url.path)")
    }
    if disabled {
        guard yuzu.allSatisfy({ !$0.isEnabled }) else { print("Yuzu is still enabled"); exit(1) }
    } else {
        guard yuzu.count == 1, let module = yuzu.first, module.isEnabled,
              expectedPath == nil || module.url.path == expectedPath else {
            print("Yuzu absent, disabled, duplicated or wrong URL"); exit(1)
        }
    }
} catch {
    print("installedExtensions failed: \(error)")
    exit(1)
}
