// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import NTFSProbe

struct InventoryTests {
    @Test func includesPartitionlessNTFSWithBlankContentHint() throws {
        let list: [String: Any] = ["AllDisksAndPartitions": [
            ["Content": "Apple_APFS_Container", "DeviceIdentifier": "disk4", "APFSVolumes": [["DeviceIdentifier": "disk4s5"]]],
            ["Content": "", "DeviceIdentifier": "disk5", "MountPoint": "/Volumes/NTFS", "Size": 268435456],
            ["Content": "GUID_partition_scheme", "DeviceIdentifier": "disk6", "Partitions": [
                ["Content": "Microsoft Basic Data", "DeviceIdentifier": "disk6s1"],
                ["Content": "Apple_APFS", "DeviceIdentifier": "disk6s2"]]]]]
        let data = try PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0)
        #expect(try NTFSInventory.candidateDevices(in: data) == ["disk5", "disk6s1"])
        #expect(throws: (any Error).self) { try NTFSInventory.candidateDevices(in: Data("invalid".utf8)) }
    }
}
