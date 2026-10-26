// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import SwiftUI
import NTFSProbe

struct TrialMenu: View {
    @Bindable var model: TrialModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Yuzu NTFS").font(.title3.bold()); Spacer(); Text("0.1.1 Beta").font(.caption).foregroundStyle(.secondary) }
            if !model.enabled {
                Button("Extension not enabled — Fix") { openWindow(id: "onboarding") }.buttonStyle(.borderedProminent)
            }
            if !model.acknowledged { Button("Review beta backup notice") { openWindow(id: "onboarding") } }
            if model.drives.isEmpty {
                ContentUnavailableView("No NTFS drives", systemImage: "externaldrive", description: Text("Plug in an NTFS drive. Writing is off until you opt in for that drive."))
            }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.drives) { drive in DriveCard(model: model, drive: drive) }
                }
            }.frame(height: model.drives.isEmpty ? 0 : min(380, CGFloat(model.drives.count) * 250))
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack {
                Button("Set up") { openWindow(id: "onboarding") }
                Button("About") { openWindow(id: "about") }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }
            Button("Export diagnostics…") { Task { await model.exportDiagnostics() } }.font(.caption)
            Button("Check for Updates…") { model.updates.check() }
            Button("Settings…") { openWindow(id: "settings") }
            Button("Disable Yuzu NTFS", role: .destructive) { Task { await model.setEnabled(false) } }.disabled(model.busy || !model.enabled)
            Text("Eject all FSKit drives before disabling. Quitting does not disable the extension.").font(.caption2).foregroundStyle(.secondary)
        }.padding(18).frame(width: 390)
        .sheet(item: $model.selectedReason) { reason in
            VStack(alignment: .leading, spacing: 18) {
                Text("Why read-only?").font(.title2.bold())
                Text(TrialModel.explanation(reason))
                Button("Done") { model.selectedReason = nil }.keyboardShortcut(.defaultAction)
            }.padding(24).frame(width: 400)
        }
    }
}
extension ReadOnlyReason: @retroactive Identifiable { public var id: String { rawValue } }

struct DriveCard: View {
    @Bindable var model: TrialModel
    let drive: TrialDrive
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "externaldrive").font(.title2).foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(drive.name).font(.headline)
                    Text("\(ByteCountFormatter.string(fromByteCount: drive.free, countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: drive.size, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(drive.writable ? "RW" : "RO").font(.caption.monospaced().bold()).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(drive.writable ? Color.green.opacity(0.14) : Color.secondary.opacity(0.12), in: Capsule())
                    .accessibilityLabel(drive.writable ? Text("Read and write") : Text("Read-only"))
            }
            if !drive.writable {
                Text(TrialModel.explanation(drive.reason ?? .requestedReadOnly)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Why read-only?") { model.selectedReason = drive.reason ?? .requestedReadOnly }.font(.caption)
            }
            if drive.rejection == nil {
                Toggle("Allow writing (beta)", isOn: Binding(get: { model.isAllowed(drive) }, set: { value in Task { await model.setWriting(value, drive: drive) } }))
                    .disabled(model.busy || !model.acknowledged || drive.status == nil)
                    .help("Unmounts and remounts this drive. Close open files first. Unsafe drives stay read-only.")
            }
            HStack {
                Button("Open") { model.open(drive) }.disabled(drive.mount == nil)
                Button("Eject") { Task { await model.eject(drive) } }.disabled(model.busy)
                Spacer()
                Text(drive.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct OnboardingView: View {
    @Bindable var model: TrialModel
    var done: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) { Text("Welcome to Yuzu NTFS").font(.title.bold()); Text("0.1.1 Beta · Apple silicon · macOS 26+").foregroundStyle(.secondary) }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Beta — keep a backup of data you can't replace").font(.headline)
                    Text("This is experimental filesystem software. Sparse, compressed and encrypted files are not writable. An error can stop new writes, but already-mapped data can still change until eject. Keep backups and safely eject every drive.")
                    Button(model.acknowledged ? String(localized: "Backup notice accepted") : String(localized: "I understand — I have a backup")) { Task { await model.acknowledge() } }
                        .buttonStyle(.borderedProminent).disabled(model.acknowledged || model.busy)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.enabled ? String(localized: "Extension enabled") : String(localized: "Enable the filesystem extension")).font(.headline)
                    Text("Yuzu enables only its own module and keeps a backup of the system preference. Eject all FSKit drives first. No reboot or reduced security is required.")
                    HStack {
                        Button("Enable Yuzu NTFS") { Task { await model.setEnabled(true) } }.buttonStyle(.borderedProminent).disabled(model.enabled || model.busy)
                        Button("Open System Settings") { model.openSettings() }
                    }
                    Text("On macOS 26: System Settings → General → Login Items & Extensions → File System Extensions. If the toggle does not work, use Enable Yuzu NTFS above.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            Text("Plug in an NTFS drive. It starts read-only. In the menu bar, turn on Allow writing (beta) for each drive you trust. Hibernated or dirty drives always stay read-only.")
            if let message = model.message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Link("Help & report an issue", destination: URL(string: "https://github.com/bluecoral-vn/yuzu-ntfs/issues/new/choose")!); Spacer(); Button("Done") { if let done { done() } else { dismiss() } }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 580).fixedSize(horizontal: false, vertical: true)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().frame(width: 96, height: 96)
            Text("Yuzu NTFS").font(.largeTitle.bold())
            Text("0.1.0 Beta (2)")
            Text("Free and open source · GNU GPL version 2 only").foregroundStyle(.secondary)
            Text("No telemetry. Diagnostics are exported only when you choose. Updates are manual for this beta.").multilineTextAlignment(.center)
            HStack { Link("yuzu.today", destination: URL(string: "https://yuzu.today")!); Link("GitHub & GPL source", destination: URL(string: "https://github.com/bluecoral-vn/yuzu-ntfs")!); Link("Report an issue", destination: URL(string: "https://github.com/bluecoral-vn/yuzu-ntfs/issues/new/choose")!) }
            HStack { Link("Support via Wise", destination: URL(string: "https://wise.com/pay/me/nguyenl447")!); Link("Support via PayPal", destination: URL(string: "https://paypal.me/nguyenrom")!) }
        }.padding(30).frame(width: 500)
    }
}
