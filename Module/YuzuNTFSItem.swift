// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import FSKit
import NTFSBridge

final class YuzuNTFSItem: FSItem {
    let ref: UInt64
    var parent: UInt64
    var version: UInt64 = 1
    let io = NSCondition()
    var operation: FSOperationID?
    var extents: [nb_extent] = []
    init(ref: UInt64, parent: UInt64) { self.ref = ref; self.parent = parent; super.init() }
    func normal<T>(_ body: () throws -> T) rethrows -> T {
        io.lock(); defer { io.unlock() }
        while operation != nil { io.wait() }
        return try body()
    }
}

final class WeakNTFSItem {
    weak var item: YuzuNTFSItem?
    init(_ item: YuzuNTFSItem) { self.item = item }
}

/// The volume's serialized bridge lock also protects this weak identity table.
final class YuzuNTFSItemTable {
    private var items: [UInt64: WeakNTFSItem] = [:]
    func item(ref: UInt64, parent: UInt64) -> YuzuNTFSItem {
        if let item = items[ref]?.item { return item }
        let item = YuzuNTFSItem(ref: ref, parent: parent)
        items[ref] = WeakNTFSItem(item)
        return item
    }
    func forget(_ item: YuzuNTFSItem) {
        if items[item.ref]?.item === item { items.removeValue(forKey: item.ref) }
    }
    func removeAll() { items.removeAll() }
}
