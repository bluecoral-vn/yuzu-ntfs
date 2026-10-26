// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import SwiftUI
import NTFSProbe

@MainActor final class TrialAppDelegate: NSObject, NSApplicationDelegate {
    let model = TrialModel()
    private var onboardingWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement apps do not automatically instantiate a SwiftUI Window scene.
        // Start observation independently of opening the menu or any window.
        model.start()
        _ = model.updates
        Task {
            await model.refresh()
            await model.restoreModuleAfterUpdate()
            if !model.acknowledged || !model.enabled { showOnboarding() }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.updates.mayTerminate() ? .terminateNow : .terminateCancel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showOnboarding() }
        return true
    }
    private func showOnboarding() {
        if let onboardingWindow { onboardingWindow.makeKeyAndOrderFront(nil) }
        else {
            let view = OnboardingView(model: model, done: { [weak self] in self?.onboardingWindow?.close() })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.setContentSize(hosting.view.fittingSize)
            window.title = String(localized: "Welcome to Yuzu NTFS")
            window.styleMask = [.titled, .closable]; window.isReleasedWhenClosed = false
            window.center(); window.makeKeyAndOrderFront(nil)
            onboardingWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
