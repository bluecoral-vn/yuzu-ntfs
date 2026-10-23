// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import SwiftUI

@main
struct YuzuNTFSApp: App {
    var body: some Scene {
        MenuBarExtra("Yuzu NTFS", systemImage: "externaldrive") {
            Text("Yuzu NTFS 0.1 Beta")
            Button("Quit", action: quit)
                .keyboardShortcut("q")
        }
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
