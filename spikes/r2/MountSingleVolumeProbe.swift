// SPDX-License-Identifier: GPL-2.0-only
// Throwaway R2 entitlement-boundary probe, not a product remounter.
// Uses a path resource only to test authorization. It does not construct a block
// device resource and cannot establish that block-device mounting would succeed.
import Foundation
import FSKit
import Darwin

@main
struct MountSingleVolumeProbe {
    static func main() async {
        guard #available(macOS 27.0, *) else { exit(2) }
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: MountSingleVolumeProbe /dev/diskN\n", stderr)
            exit(2)
        }
        let resource = FSPathURLResource(url: URL(fileURLWithPath: CommandLine.arguments[1]), writable: false)
        let start = ContinuousClock.now
        do {
            let path = try await FSClient.shared.mountSingleVolume(
                resource: resource,
                bundleID: "com.bluecoral.vn.yuzuntfs.fsmodule",
                options: ["-o", "ro"])
            print("mount path=\(path) elapsed=\(start.duration(to: .now))")
        } catch {
            let e = error as NSError
            print("domain=\(e.domain) code=\(e.code) description=\(e.localizedDescription) elapsed=\(start.duration(to: .now))")
            exit(1)
        }
    }
}
