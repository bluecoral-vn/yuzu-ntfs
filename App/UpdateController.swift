// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import NTFSProbe
import Sparkle

@MainActor final class UpdateController: NSObject, SPUUpdaterDelegate {
    private weak var model: TrialModel?
    private var pendingInstallation: (() -> Void)?
    private var watcher: Task<Void, Never>?
    private var waitingAlert: NSAlert?
    private var updateReady = false
    private(set) var controller: SPUStandardUpdaterController!
    init(model: TrialModel) {
        self.model = model
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    func check() { controller.checkForUpdates(nil) }
    func feedURLString(for updater: SPUUpdater) -> String? {
        // Explicit VM-only QA: production host launches can never redirect the feed.
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--qa-update-feed"),
              arguments.indices.contains(index + 1),
              let url = URL(string: arguments[index + 1]),
              url.scheme == "http", url.host == "192.168.64.1", url.port == 8787,
              url.path == "/appcast-local.xml" else { return nil }
        var virtualized: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_vmm_present", &virtualized, &size, nil, 0) == 0,
              virtualized == 1 else { return nil }
        return url.absoluteString
    }
    static func mustWait() -> Bool {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        process.standardOutput = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return true }
            return UpdateSafety.shouldPostpone(mountInventory: String(decoding: data, as: UTF8.self), home: NSHomeDirectory())
        } catch { return true }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard Self.mustWait() else { return false }
        pendingInstallation = installHandler
        model?.message = String(localized: "Eject all Yuzu NTFS and other FSKit drives to install the update. Installation will resume automatically after ejecting.")
        let alert = NSAlert()
        alert.messageText = String(localized: "Eject drives before updating")
        alert.informativeText = model?.message ?? ""
        waitingAlert = alert
        alert.window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if !Self.mustWait() {
                    let handler = pendingInstallation
                    pendingInstallation = nil
                    model?.message = nil
                    waitingAlert?.window.close()
                    waitingAlert = nil
                    handler?()
                    return
                }
            }
        }
        return true
    }
    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        updateReady = true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        updateReady = false
        pendingInstallation = nil
        watcher?.cancel()
        waitingAlert?.window.close()
        waitingAlert = nil
    }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        UserDefaults.standard.set(model?.enabled == true, forKey: "UpdateModuleWasEnabled")
    }
    func mayTerminate() -> Bool {
        // Sparkle's on-quit install path must not bypass the same volume guard.
        guard updateReady || pendingInstallation != nil else { return true }
        guard !Self.mustWait() else {
            model?.message = String(localized: "Eject all Yuzu NTFS and other FSKit drives before quitting or updating.")
            return false
        }
        return true
    }
}
