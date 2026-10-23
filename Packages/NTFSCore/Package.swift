// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-2.0-only
import PackageDescription

let upstream = Context.packageDirectory + "/../../upstream/ttntfs"

let package = Package(
    name: "NTFSCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NTFSProbe", targets: ["NTFSProbe"]),
        .library(name: "NTFSBridge", targets: ["NTFSBridge"]),
        .library(name: "EngineE2", targets: ["EngineE2"])
    ],
    targets: [
        .target(name: "NTFSProbe"),
        .testTarget(name: "NTFSProbeTests", dependencies: ["NTFSProbe"]),
        .target(name: "NTFSBridge"),
        .target(name: "EngineE2", dependencies: ["NTFSBridge"], exclude: ["PATCHES.md"], cSettings: [
            .unsafeFlags([
                "-I" + upstream + "/core/include",
                "-I" + upstream + "/platform/include",
                "-iquote", upstream + "/core/ntfs",
                "-iquote", upstream + "/core/vfs",
                "-iquote", upstream + "/core/logfile",
                "-iquote", upstream + "/platform/pagecache",
                "-fno-strict-aliasing", "-fwrapv", "-fno-modules"
            ])
        ]),
        // Compile the actual app-extension glue in a plain Swift Testing host.
        // Source symlinks retain Module/ as the single implementation owner.
        .target(name: "FSKitGlue", dependencies: ["NTFSProbe", "NTFSBridge", "EngineE2"]),
        .testTarget(name: "FSKitGlueTests", dependencies: ["FSKitGlue", "NTFSBridge"]),
        .testTarget(name: "BridgeConformanceTests", dependencies: ["NTFSBridge", "EngineE2"])
    ]
)
