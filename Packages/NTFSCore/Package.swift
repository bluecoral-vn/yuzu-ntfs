// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-2.0-only
import PackageDescription

let package = Package(
    name: "NTFSCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "NTFSProbe", targets: ["NTFSProbe"])],
    targets: [
        .target(name: "NTFSProbe"),
        .testTarget(name: "NTFSProbeTests", dependencies: ["NTFSProbe"])
    ]
)
