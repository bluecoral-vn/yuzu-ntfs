// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import SwiftUI

@main
struct YuzuNTFSApp: App {
    @NSApplicationDelegateAdaptor(TrialAppDelegate.self) private var delegate
    private var model: TrialModel { delegate.model }
    var body: some Scene {
        MenuBarExtra("Yuzu NTFS", systemImage: "externaldrive") { TrialMenu(model: model) }
            .menuBarExtraStyle(.window)
        Window("Yuzu NTFS — Set up", id: "onboarding") {
            OnboardingView(model: model)
        }.windowResizability(.contentSize)
        Window("About Yuzu NTFS", id: "about") { AboutView() }
            .windowResizability(.contentSize).defaultLaunchBehavior(.suppressed)
    }
}
