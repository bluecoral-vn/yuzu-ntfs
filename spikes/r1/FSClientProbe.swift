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
    for module in modules {
        print("\(module.bundleIdentifier) enabled=\(module.isEnabled) url=\(module.url.path)")
    }
} catch {
    print("installedExtensions failed: \(error)")
    exit(1)
}
