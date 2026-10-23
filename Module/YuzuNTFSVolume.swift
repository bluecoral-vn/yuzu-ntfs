// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import FSKit
import NTFSBridge
import EngineE2
import NTFSProbe

/// One macOS 26-compatible protocol path, also supported by the macOS 27 SDK.
final class YuzuNTFSVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations, FSVolume.OpenCloseOperations, FSVolumeKernelOffloadedIOOperations {
    let device: YuzuNTFSDevice
    let boot: NTFSBootSector
    let writable: Bool
    static func inhibitsIO(flags: UInt32, writable: Bool) -> Bool {
        !allowsWrite(flags: flags) || (!writable && flags & UInt32(NB_RESIDENT) != 0)
    }
    static func allowsWrite(flags: UInt32) -> Bool {
        flags & UInt32(NB_COMPRESSED | NB_ENCRYPTED) == 0
    }
    let api = nb_engine_e2()!.pointee
    private let lock = NSRecursiveLock()
    private var core: OpaquePointer?
    private let items = YuzuNTFSItemTable()
    private var rootRef: UInt64 = 5
    init(device: FSBlockDeviceResource, boot: NTFSBootSector, readOnly: Bool = false) {
        self.device = YuzuNTFSDevice(device)
        self.boot = boot
        writable = !readOnly && WriteAllowlist.permits(serial: boot.serial, contents: try? String(contentsOf: WriteAllowlist.fileURL, encoding: .utf8)) && device.isWritable
        super.init(volumeID: FSVolume.Identifier(uuid: boot.volumeUUID), volumeName: FSFileName(string: "Yuzu-NTFS"))
    }
    private func check(_ code: Int32) throws { if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) } }
    private func serial<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    private func node(_ item: FSItem) -> YuzuNTFSItem { item as! YuzuNTFSItem }
    private func identity(_ ref: UInt64, parent: UInt64) -> YuzuNTFSItem {
        items.item(ref: ref, parent: parent)
    }
    private func id(_ ref: UInt64) -> FSItem.Identifier { ref == rootRef ? .rootDirectory : FSItem.Identifier(ref + 16) }
    private func units(_ name: FSFileName) throws -> [UInt16] {
        guard let text = name.string else { throw POSIXError(.EILSEQ) }
        return Array(text.utf16)
    }
    private func attributes(_ item: YuzuNTFSItem) throws -> FSItem.Attributes {
        var attr = nb_attr()
        try check(api.nb_getattr!(core, item.ref, item.parent, &attr))
        return attributes(attr)
    }
    private func attributes(_ attr: nb_attr) -> FSItem.Attributes {
        let result = FSItem.Attributes()
        result.type = attr.type == NB_DIR ? .directory : attr.type == NB_SYMLINK ? .symlink : .file
        result.mode = attr.type == NB_DIR ? 0o755 : 0o644
        result.uid = getuid(); result.gid = getgid()
        result.linkCount = attr.nlink
        result.size = attr.size; result.allocSize = attr.alloc_size
        result.fileID = id(attr.ref); result.parentID = id(attr.parent_ref)
        result.flags = attr.ntfs_attrs & 2 != 0 ? UInt32(UF_HIDDEN) : 0
        // T7-R4: on RW mounts the first actual mapping promotes resident data.
        // RO resident reads stay on the byte-copy path and never mutate disk.
        result.inhibitKernelOffloadedIO = attr.type != NB_FILE || Self.inhibitsIO(flags: attr.flags, writable: writable)
        result.modifyTime = time(attr.mtime); result.changeTime = time(attr.ctime)
        result.accessTime = time(attr.atime); result.birthTime = time(attr.crtime)
        return result
    }
    private func time(_ ticks: Int64) -> timespec {
        let seconds = ticks / 10_000_000 - 11_644_473_600
        return timespec(tv_sec: Int(seconds), tv_nsec: Int(ticks % 10_000_000) * 100)
    }
    private func ticks(_ time: timespec) -> Int64 { (Int64(time.tv_sec) + 11_644_473_600) * 10_000_000 + Int64(time.tv_nsec / 100) }
    private func apply(_ request: FSItem.SetAttributesRequest, to item: YuzuNTFSItem) throws {
        var a = nb_attr(), valid: UInt32 = 0
        if request.isValid(.size) {
            var current = nb_attr(); try check(api.nb_getattr!(core, item.ref, item.parent, &current))
            if !Self.allowsWrite(flags: current.flags) { throw POSIXError(.EPERM) }
            if current.type == NB_FILE { a.size = request.size; valid |= UInt32(NB_SET_SIZE) }
        }
        if request.isValid(.modifyTime) { a.mtime = ticks(request.modifyTime); valid |= UInt32(NB_SET_MTIME) }
        if request.isValid(.accessTime) { a.atime = ticks(request.accessTime); valid |= UInt32(NB_SET_ATIME) }
        if request.isValid(.birthTime) { a.crtime = ticks(request.birthTime); valid |= UInt32(NB_SET_CRTIME) }
        if valid != 0 { try check(api.nb_setattr!(core, item.ref, &a, valid)) }
        for attribute: FSItem.Attribute in [.size, .modifyTime, .accessTime, .birthTime] where request.isValid(attribute) {
            request.consumedAttributes.insert(attribute)
        }
    }
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping ((any Error)?) -> Void) {
        do {
            try serial {
                if modes.contains(.write) {
                    guard writable else { throw POSIXError(.EROFS) }
                    var a = nb_attr(); try check(api.nb_getattr!(core, node(item).ref, node(item).parent, &a))
                    if !Self.allowsWrite(flags: a.flags) { throw POSIXError(.EPERM) }
                }
            }
            reply(nil)
        } catch { reply(error) }
    }
    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping ((any Error)?) -> Void) {
        // The bridge owns no per-open handle; FSKit owns cached data and close.
        reply(nil)
    }
    var maximumLinkCount: Int { 65535 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { false }
    var truncatesLongNames: Bool { false }
    var enableOpenUnlinkEmulation: Bool { true }
    @available(macOS 26.4, *)
    var requestedMountOptions: FSVolume.MountOptions { writable ? [] : [.readOnly] }
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let c = FSVolume.SupportedCapabilities()
        c.caseFormat = .sensitive // E2 P0 deliberately preserves distinct NFC/NFD names.
        c.supports64BitObjectIDs = true; c.supports2TBFiles = true
        c.supportsSparseFiles = true; c.supportsZeroRuns = true
        c.doesNotSupportSettingFilePermissions = true
        c.doesNotSupportImmutableFiles = true
        return c
    }
    var volumeStatistics: FSStatFSResult {
        serial {
            let result = FSStatFSResult(fileSystemTypeName: "yuzuntfs")
            var s = nb_stat()
            if core != nil, api.nb_statfs!(core, &s) == 0 {
                result.blockSize = Int(s.block_size); result.ioSize = 8 * 1024 * 1024
                result.totalBlocks = s.total_blocks; result.freeBlocks = s.free_blocks; result.availableBlocks = s.free_blocks
                result.totalFiles = s.total_files; result.freeFiles = s.free_files
            }
            return result
        }
    }
    func activate(options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void) {
        do {
            let root = try serial {
                var dev = device.blockdev
                try check(api.nb_mount!(&dev, writable ? 1 : 0, &core))
                rootRef = api.nb_root_ref!(core)
                return identity(rootRef, parent: rootRef)
            }
            reply(root, nil)
        } catch { reply(nil, error) }
    }
    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        serial { device.metadataActive = true }; reply(nil)
    }
    func unmount(replyHandler reply: @escaping () -> Void) {
        serial { if let core { _ = api.nb_sync!(core); _ = api.nb_unmount!(core); self.core = nil } }
        reply()
    }
    func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping ((any Error)?) -> Void) { serial { items.removeAll() }; reply(nil) }
    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        do { try serial { try check(api.nb_sync!(core)) }; reply(nil) } catch { reply(error) }
    }
    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        serial {
            let clear = { self.items.forget(self.node(item)) }
            if #available(macOS 27, *) { _ = item.tryReclaim(clear) } else { clear() }
        }
        reply(nil)
    }
    func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        do {
            let item = try serial {
                let nameUnits = try units(name); var a = nb_attr()
                try check(api.nb_lookup!(core, node(directory).ref, nameUnits, nameUnits.count, &a))
                return identity(a.ref, parent: a.parent_ref)
            }
            reply(item, name, nil)
        } catch { reply(nil, nil, error) }
    }
    func getAttributes(_ request: FSItem.GetAttributesRequest, of item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        do { let a = try serial { try attributes(node(item)) }; reply(a, nil) } catch { reply(nil, error) }
    }
    func setAttributes(_ request: FSItem.SetAttributesRequest, on item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        do { let a = try node(item).normal { try serial { try apply(request, to: node(item)); return try attributes(node(item)) } }; reply(a, nil) } catch { reply(nil, error) }
    }
    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes request: FSItem.SetAttributesRequest, replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        do {
            let item = try serial {
                guard type == .file || type == .directory else { throw POSIXError(.ENOTSUP) }
                var a = nb_attr(); let u = try units(name)
                try check(api.nb_create!(core, node(directory).ref, u, u.count, UInt32(type == .directory ? NB_DIR : NB_FILE), &a))
                let item = identity(a.ref, parent: a.parent_ref)
                try apply(request, to: item); node(directory).version &+= 1
                return item
            }
            reply(item, name, nil)
        } catch { reply(nil, nil, error) }
    }
    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        do { try node(item).normal { try serial {
            let u = try units(name); try check(api.nb_remove!(core, node(directory).ref, u, u.count)); node(directory).version &+= 1
        } }; reply(nil) } catch { reply(error) }
    }
    func renameItem(_ item: FSItem, inDirectory source: FSItem, named old: FSFileName, to new: FSFileName, inDirectory destination: FSItem, overItem: FSItem?, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        do { try node(item).normal { try serial {
            let a = try units(old), b = try units(new)
            try check(api.nb_rename!(core, node(source).ref, a, a.count, node(destination).ref, b, b.count))
            node(item).parent = node(destination).ref; node(source).version &+= 1; node(destination).version &+= 1
        } }; reply(new, nil) } catch { reply(nil, error) }
    }
    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes request: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        do {
            let version = try serial {
                let item = node(directory)
                guard verifier.rawValue == 0 || verifier.rawValue == item.version else { throw POSIXError(.ESTALE) }
                if request == nil {
                    if cookie.rawValue == 0 && !packer.packEntry(name: FSFileName(string: "."), itemType: .directory, itemID: id(item.ref), nextCookie: FSDirectoryCookie(rawValue: 1), attributes: nil) { return item.version }
                    if cookie.rawValue <= 1 && !packer.packEntry(name: FSFileName(string: ".."), itemType: .directory, itemID: id(item.parent), nextCookie: FSDirectoryCookie(rawValue: 2), attributes: nil) { return item.version }
                }
                let context = Enumeration(volume: self, packer: packer, attributes: request != nil)
                try check(api.nb_readdir!(core, item.ref, cookie.rawValue > 2 ? cookie.rawValue - 2 : 0, { opaque, name, count, attr, next in
                    let c = Unmanaged<Enumeration>.fromOpaque(opaque!).takeUnretainedValue()
                    let a = attr!.pointee
                    let text = String(decoding: UnsafeBufferPointer(start: name, count: count), as: UTF16.self)
                    return c.packer.packEntry(name: FSFileName(string: text), itemType: a.type == NB_DIR ? .directory : .file,
                        itemID: c.volume.id(a.ref), nextCookie: FSDirectoryCookie(rawValue: next + 2), attributes: c.attributes ? c.volume.attributes(a) : nil) ? 0 : 1
                }, Unmanaged.passUnretained(context).toOpaque()))
                return item.version
            }
            reply(FSDirectoryVerifier(rawValue: version), nil)
        } catch { reply(verifier, error) }
    }
    private final class Enumeration {
        let volume: YuzuNTFSVolume, packer: FSDirectoryEntryPacker
        let attributes: Bool
        init(volume: YuzuNTFSVolume, packer: FSDirectoryEntryPacker, attributes: Bool) { self.volume = volume; self.packer = packer; self.attributes = attributes }
    }
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        do {
            guard offset >= 0 else { throw POSIXError(.EINVAL) }
            var got = 0
            try node(item).normal { try serial { try buffer.withUnsafeMutableBytes { bytes in
                try check(api.nb_read!(core, node(item).ref, UInt64(offset), bytes.baseAddress, min(length, bytes.count), &got))
            } } }
            reply(got, nil)
        } catch { reply(0, error) }
    }
    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        do {
            guard offset >= 0 else { throw POSIXError(.EINVAL) }
            try node(item).normal { try serial {
                var a = nb_attr(); try check(api.nb_getattr!(core, node(item).ref, node(item).parent, &a))
                guard Self.allowsWrite(flags: a.flags) else { throw POSIXError(.EPERM) }
                try contents.withUnsafeBytes { bytes in
                    try check(api.nb_write!(core, node(item).ref, UInt64(offset), bytes.baseAddress, bytes.count))
                }
            } }
            reply(contents.count, nil)
        } catch { reply(0, error) }
    }
    func blockmapFile(_ file: FSItem, offset: off_t, length: Int, flags: FSBlockmapFlags, operationID: FSOperationID, packer: FSExtentPacker, replyHandler reply: @escaping ((any Error)?) -> Void) {
        let item = node(file); item.io.lock()
        while item.operation != nil && item.operation != operationID { item.io.wait() }
        do {
            guard offset >= 0 else { throw POSIXError(.EINVAL) }
            if operationID != .unspecified { item.operation = operationID }
            try serial {
                var extents = [nb_extent](repeating: nb_extent(), count: 128), count = 0
                try check(api.nb_blockmap!(core, item.ref, UInt64(offset), UInt64(length), flags.contains(.write) ? 1 : 0, &extents, extents.count, &count))
                extents.removeSubrange(count...)
                try device.purge(extents)
                item.extents.append(contentsOf: extents)
                for extent in extents {
                    var done: UInt64 = 0
                    while done < extent.length {
                        let chunk = min(extent.length - done, UInt64(UInt32.max) & ~UInt64(4095))
                        let zero = extent.kind == NB_EXT_HOLE || (extent.kind == NB_EXT_UNINIT && !flags.contains(.write))
                        if !packer.packExtent(resource: device.resource, type: zero ? .zeroFill : .data,
                            logicalOffset: off_t(extent.logical + done), physicalOffset: off_t(extent.physical + done), length: Int(chunk)) { return }
                        done += chunk
                    }
                }
            }
            item.io.unlock(); reply(nil)
        } catch {
            item.operation = nil; item.extents.removeAll(keepingCapacity: true); item.io.broadcast(); item.io.unlock(); reply(error)
        }
    }
    // SDK 27 incorrectly annotates status nonnull; its own contract specifies
    // nil for success. Keep Optional to avoid trapping on successful I/O.
    func completeIO(for file: FSItem, offset: off_t, length: Int, status: (any Error)?, flags: FSCompleteIOFlags, operationID: FSOperationID, replyHandler reply: @escaping ((any Error)?) -> Void) {
        let item = node(file); item.io.lock()
        do {
            try serial {
                try device.purge(item.extents)
                try check(api.nb_complete_io!(core, item.ref, UInt64(offset), UInt64(length), status.map { Int32(($0 as NSError).code) } ?? 0, flags.contains(.write) ? 1 : 0))
                try device.purge(item.extents)
            }
            item.operation = nil; item.extents.removeAll(keepingCapacity: true); item.io.broadcast(); item.io.unlock(); reply(nil)
        } catch {
            item.operation = nil; item.extents.removeAll(keepingCapacity: true); item.io.broadcast(); item.io.unlock(); reply(error)
        }
    }
    func createFile(name: FSFileName, in directory: FSItem, attributes: FSItem.SetAttributesRequest, packer: FSExtentPacker, replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) { createItem(named: name, type: .file, inDirectory: directory, attributes: attributes, replyHandler: replyHandler) }
    func lookupItem(name: FSFileName, in directory: FSItem, packer: FSExtentPacker, replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) { lookupItem(named: name, inDirectory: directory, replyHandler: replyHandler) }
    func createSymbolicLink(named: FSFileName, inDirectory: FSItem, attributes: FSItem.SetAttributesRequest, linkContents: FSFileName, replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) { replyHandler(nil, nil, POSIXError(.ENOTSUP)) }
    func createLink(to item: FSItem, named: FSFileName, inDirectory: FSItem, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) { replyHandler(nil, POSIXError(.ENOTSUP)) }
    func readSymbolicLink(_ item: FSItem, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) { replyHandler(nil, POSIXError(.ENOTSUP)) }
}
