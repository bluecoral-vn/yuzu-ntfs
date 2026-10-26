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
        Window("Settings", id: "settings") {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { model.updates.automaticallyChecks },
                    set: { model.updates.automaticallyChecks = $0 }))
                Button("Check for Updates…") { model.updates.check() }
            }.padding(24).frame(width: 360)
        }.windowResizability(.contentSize).defaultLaunchBehavior(.suppressed)
    }
}
