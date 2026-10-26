// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import SwiftUI
import NTFSProbe

// Explicit opt-in, VM-only control. Calls the same model actions as the UI; never changes admission rules.
@MainActor final class TrialQA {
    private var window: NSWindow?
    private let directory: URL
    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--qa-control"), arguments.indices.contains(index + 1) else { return nil }
        var virtualized: Int32 = 0; var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_vmm_present", &virtualized, &size, nil, 0) == 0, virtualized == 1 else { return nil }
        directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }
    func consume(model: TrialModel) async {
        let input = directory.appendingPathComponent("command.json")
        guard let data = try? Data(contentsOf: input), let command = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        try? FileManager.default.removeItem(at: input)
        switch command["action"] {
        case "ack": await model.acknowledge()
        case "enable": await model.setEnabled(true)
        case "disable": await model.setEnabled(false)
        case "check-updates": model.updates.check()
        case "writing-on", "writing-off":
            if let drive = model.drives.first(where: { $0.id == command["device"] }) { await model.setWriting(command["action"] == "writing-on", drive: drive) }
            else { model.message = "QA drive not found" }
        case "eject":
            if let drive = model.drives.first(where: { $0.id == command["device"] }) { await model.eject(drive) }
            else { model.message = "QA drive not found" }
        case "menu", "onboarding":
            let content: AnyView = command["action"] == "menu" ? AnyView(TrialMenu(model: model)) : AnyView(OnboardingView(model: model))
            window?.close()
            let hosting = NSHostingController(rootView: content)
            let created = NSWindow(contentViewController: hosting)
            created.setContentSize(hosting.view.fittingSize)
            created.isReleasedWhenClosed = false
            created.title = "Yuzu NTFS"; created.styleMask = [.titled, .closable]; created.center(); created.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true); window = created
        case "status": break
        default: model.message = "Unknown QA action"
        }
        await model.refresh()
        let result: [String: Any] = ["id": command["id"] ?? "", "version": TrialModel.version, "build": TrialModel.build,
            "enabled": model.enabled, "acknowledged": model.acknowledged,
            "error": model.message ?? "", "drives": model.drives.map { drive -> [String: Any] in
                ["device": drive.id, "name": drive.name, "mount": drive.mount ?? "", "writable": drive.writable,
                 "allowed": model.isAllowed(drive), "reason": drive.reason?.rawValue ?? "unknown", "serial": drive.status.map { String(format: "%016llX", $0.serial) } ?? ""]
            }]
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("result.json"), options: .atomic) }
        catch { model.message = error.localizedDescription }
    }
}
