// SPDX-License-Identifier: GPL-2.0-only
import Testing
import FSKit
import NTFSBridge
@testable import FSKitGlue

@Test func staleLegacyReclaimPreservesRepublishedIdentityAndPin() {
    let table = YuzuNTFSItemTable()
    var releases = 0
    var item: YuzuNTFSItem? = table.item(ref: 42, parent: 5)
    item!.releasePin = { releases += 1 }
    table.publish(ref: 42, parent: 5, initialize: { _ in }) { #expect($0 === item) }
    YuzuNTFSVolume.reclaimLegacy(item!, table: table)
    #expect(table.item(ref: 42, parent: 5) === item)
    #expect(releases == 0)
    item = nil
    #expect(releases == 1)
}

@Test func oneLiveItemPerMFTReference() {
    let table = YuzuNTFSItemTable()
    let first = table.item(ref: 42, parent: 5)
    #expect(table.item(ref: 42, parent: 7) === first)
    #expect(table.item(ref: 43, parent: 5) !== first)
    // An obsolete reclaim must not remove a newer object at the same ref.
    table.forget(first)
    let next = table.item(ref: 42, parent: 5)
    table.forget(first)
    #expect(table.item(ref: 42, parent: 5) === next)
}

@Test func itemTableDoesNotRetainDeadItems() {
    let table = YuzuNTFSItemTable()
    weak var weakItem: YuzuNTFSItem?
    do {
        let item = table.item(ref: 42, parent: 5)
        weakItem = item
        #expect(table.item(ref: 42, parent: 5) === item)
    }
    #expect(weakItem == nil)
    let new = table.item(ref: 42, parent: 7)
    #expect(new.parent == 7)
}

@Test func p0ResidencyRoutingAndWriteSafety() {
    #expect(!YuzuNTFSVolume.inhibitsIO(flags: 0, writable: false))
    #expect(!YuzuNTFSVolume.inhibitsIO(flags: UInt32(NB_RESIDENT), writable: true))
    #expect(YuzuNTFSVolume.inhibitsIO(flags: UInt32(NB_RESIDENT), writable: false))
    for flag in [UInt32(NB_SPARSE), UInt32(NB_READ_ONLY), UInt32(NB_COMPRESSED), UInt32(NB_ENCRYPTED), UInt32(NB_RESIDENT | NB_COMPRESSED)] {
        #expect(YuzuNTFSVolume.inhibitsIO(flags: flag, writable: true))
        #expect(YuzuNTFSVolume.inhibitsIO(flags: flag, writable: false))
        #expect(!YuzuNTFSVolume.allowsWrite(flags: flag))
    }
    #expect(!YuzuNTFSVolume.allowsWrite(flags: UInt32(NB_RESIDENT | NB_SPARSE)))
}
