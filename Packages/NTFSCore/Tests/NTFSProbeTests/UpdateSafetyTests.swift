// SPDX-License-Identifier: GPL-2.0-only
import Testing
@testable import NTFSProbe

@Test func updateWaitsForFilesystemVolumes() {
    #expect(UpdateSafety.shouldPostpone(mountInventory: nil, home: "/Users/test"))
    #expect(UpdateSafety.shouldPostpone(mountInventory: "invalid", home: "/Users/test"))
    #expect(UpdateSafety.shouldPostpone(mountInventory: "/dev/disk9 on /Volumes/Test (yuzuntfs, local)", home: "/Users/test"))
    #expect(!UpdateSafety.shouldPostpone(mountInventory: "/dev/disk1 on / (apfs, local)", home: "/Users/test"))
}
@Test func updateReenableRequiresNewBuildAndSafeInventory() {
    #expect(UpdateSafety.shouldReenable(previousBuild: "3", currentBuild: "4", wasEnabled: true, moduleEnabled: false, activeVolumes: false))
    #expect(!UpdateSafety.shouldReenable(previousBuild: "3", currentBuild: "4", wasEnabled: true, moduleEnabled: false, activeVolumes: true))
    #expect(!UpdateSafety.shouldReenable(previousBuild: "3", currentBuild: "3", wasEnabled: true, moduleEnabled: false, activeVolumes: false))
    #expect(!UpdateSafety.shouldReenable(previousBuild: nil, currentBuild: "4", wasEnabled: true, moduleEnabled: false, activeVolumes: false))
    #expect(!UpdateSafety.shouldReenable(previousBuild: "3", currentBuild: "4", wasEnabled: false, moduleEnabled: false, activeVolumes: false))
    #expect(!UpdateSafety.shouldReenable(previousBuild: "3", currentBuild: "4", wasEnabled: true, moduleEnabled: true, activeVolumes: false))
}
