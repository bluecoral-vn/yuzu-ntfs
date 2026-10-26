// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import FSKit
import NTFSBridge
import EngineE2
import NTFSProbe
import OSLog

/// One macOS 26-compatible protocol path, also supported by the macOS 27 SDK.
final class YuzuNTFSVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations, FSVolume.OpenCloseOperations, FSVolumeKernelOffloadedIOOperations {
    let device: any YuzuNTFSDeviceAccess
    private static let p0Log = Logger(subsystem: "com.bluecoral.vn.yuzuntfs.fsmodule", category: "P0KOIO")
    let boot: NTFSBootSector
    let writable: Bool
    static func inhibitsIO(flags: UInt32, writable: Bool) -> Bool {
        !allowsWrite(flags: flags) || (!writable && flags & UInt32(NB_RESIDENT | NB_UNALIGNED_VDL) != 0)
    }
    static func allowsWrite(flags: UInt32) -> Bool {
        flags & UInt32(NB_COMPRESSED | NB_ENCRYPTED | NB_SPARSE | NB_READ_ONLY) == 0
    }
    private static func validRange(offset: off_t, length: Int) -> Bool {
        offset >= 0 && length >= 0 && UInt64(length) <= UInt64(Int64.max) - UInt64(offset)
    }
    static func reclaimLegacy(_ item: YuzuNTFSItem, table: YuzuNTFSItemTable) {
        // macOS 26 cannot confirm the SDK's publication/reclaim count.
        // Keep the weak identity and inode pin until actual deinitialization.
    }
    let api: nb_engine
    private var core: OpaquePointer?
    private var terminalReadOnly = false {
        didSet {
            if terminalReadOnly && !oldValue {
                sharedStatus?.writable = false
                sharedStatus?.reason = .engineError
                publishStatus()
            }
        }
    }
    private var checkpointTimer: DispatchSourceTimer?
    // Fault injection only reduces permissions; it cannot admit writes.
    var forceReadOnlyURL = (BetaPolicy.directory ?? FileManager.default.temporaryDirectory)
        .appendingPathComponent("force-read-only")
    private var sharedStatus: VolumeStatus?
    private let statusDirectory: URL?
    private func publishStatus() {
        sharedStatus?.updatedAt = Date()
        guard let directory = statusDirectory, let sharedStatus else { return }
        do { try sharedStatus.write(at: directory) }
        catch { Self.p0Log.error("Cannot publish volume status: \(error.localizedDescription)") }
    }
    #if DEBUG
    var beforeSizeLock: (() -> Void)?
    #endif
    private func effectivelyWritable() -> Bool {
        guard writable, core != nil, !terminalReadOnly else { return false }
        if FileManager.default.fileExists(atPath: forceReadOnlyURL.path) { terminalReadOnly = true }
        var state = nb_stat()
        if api.nb_statfs!(core, &state) != 0 || state.read_only != 0 { terminalReadOnly = true }
        return !terminalReadOnly
    }
    private let items = YuzuNTFSItemTable()
    private var rootRef: UInt64 = 5
    convenience init(device: FSBlockDeviceResource, boot: NTFSBootSector, readOnly: Bool = false) throws {
        let adapter = try YuzuNTFSDevice(device)
        let api = nb_engine_e2()!.pointee
        var dev = adapter.blockdev
        var state = NB_UNSUPPORTED
        let probeError = api.nb_probe_state!(&dev, &state)
        let directory = BetaPolicy.directory
        let acknowledged = BetaPolicy.acknowledged(at: directory)
        let allowlist = directory.flatMap { try? String(contentsOf: $0.appendingPathComponent("write-serials.txt"), encoding: .utf8) }
        let allowed = WriteAllowlist.permits(serial: boot.serial, contents: allowlist)
        let identity = DiskIdentity.read(device: device.bsdName)
        let clean = probeError == 0 && state == NB_CLEAN
        let writable = !readOnly && device.isWritable && identity?.deviceWritable == true && BetaPolicy.admits(serial: boot.serial,
            acknowledgement: acknowledged ? BetaPolicy.acknowledgement : nil, allowlist: allowlist, clean: clean)
        let reason: ReadOnlyReason
        if probeError != 0 || identity == nil { reason = .engineError }
        else if !clean {
            switch state {
            case NB_HIBERNATED: reason = .hibernated
            case NB_FAST_STARTUP: reason = .fastStartup
            case NB_DIRTY_LOG: reason = .dirtyLog
            case NB_DIRTY_FLAG: reason = .dirtyFlag
            case NB_BITLOCKER: reason = .bitlocker
            default: reason = .unsupported
            }
        } else {
            reason = .forCleanDevice(mediaWritable: identity?.deviceWritable == true, resourceWritable: device.isWritable,
                                     acknowledged: acknowledged, allowed: allowed, requestedReadOnly: readOnly)
        }
        let status = identity.map {
            VolumeStatus(serial: boot.serial, identity: $0, writable: writable, reason: reason)
        }
        self.init(device: adapter, boot: boot, writable: writable, api: api, status: status, statusDirectory: directory)
    }
    init(device: any YuzuNTFSDeviceAccess, boot: NTFSBootSector, writable: Bool, api: nb_engine,
         status: VolumeStatus? = nil, statusDirectory: URL? = nil) {
        self.device = device
        self.boot = boot
        self.writable = writable
        self.api = api
        sharedStatus = status
        self.statusDirectory = statusDirectory
        super.init(volumeID: FSVolume.Identifier(uuid: boot.volumeUUID), volumeName: FSFileName(string: "Yuzu-NTFS"))
        publishStatus()
    }
    deinit {
        checkpointTimer?.cancel()
        if let core { _ = api.nb_dispose!(core) }
        // Callback I/O is drained; deinit owns the remaining state exclusively.
        withdrawStatusLocked()
    }
    private func discardCore() {
        checkpointTimer?.cancel()
        checkpointTimer = nil
        if let core { _ = api.nb_dispose!(core); self.core = nil }
        items.removeAll()
        device.metadataActive = false
    }
    private func check(_ code: Int32) throws { if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) } }
    func withdrawStatus() { serial { withdrawStatusLocked() } }
    private func withdrawStatusLocked() {
        defer { sharedStatus = nil }
        guard let statusDirectory, let sharedStatus else { return }
        do { try sharedStatus.remove(at: statusDirectory) }
        catch { Self.p0Log.error("Cannot remove volume status: \(error.localizedDescription)") }
    }
    private func serial<T>(_ body: () throws -> T) rethrows -> T {
        try items.withLock {
            if core != nil && FileManager.default.fileExists(atPath: forceReadOnlyURL.path) { terminalReadOnly = true }
            return try body()
        }
    }
    /// Maintenance must not issue plain resource reads alongside active KOIO/cache I/O.
    func withUnactivatedResource<T>(_ body: () throws -> T) throws -> T {
        try serial {
            guard core == nil else { throw POSIXError(.EBUSY) }
            return try body()
        }
    }
    private func node(_ item: FSItem) throws -> YuzuNTFSItem {
        guard let node = item as? YuzuNTFSItem else { throw POSIXError(.EINVAL) }
        return node
    }
    private func publish(_ ref: UInt64, parent: UInt64,
                         prepare: (YuzuNTFSItem) throws -> Void = { _ in },
                         reply: (YuzuNTFSItem) -> Void) throws {
        try items.publish(ref: ref, parent: parent, initialize: { item in
            if item.releasePin == nil {
                try check(api.nb_hold!(core, ref))
                item.releasePin = { [weak self] in
                    guard let self else { return }
                    self.serial { if let core = self.core { _ = self.api.nb_release!(core, ref) } }
                }
            }
            if item.inhibitsKernelIO == nil {
                var attr = nb_attr()
                try check(api.nb_getattr!(core, ref, parent, &attr))
                item.inhibitsKernelIO = attr.type != NB_FILE || Self.inhibitsIO(flags: attr.flags, writable: effectivelyWritable())
                Self.p0Log.info("publish ref=\(ref) flags=\(attr.flags) size=\(attr.size) inhibit=\(item.inhibitsKernelIO == true)")
            }
            try prepare(item)
        }, reply: reply)
    }
    private func id(_ ref: UInt64) throws -> FSItem.Identifier {
        ref == rootRef ? .rootDirectory : FSItem.Identifier(try YuzuNTFSBoundary.adding(ref, 16))
    }
    private func units(_ name: FSFileName) throws -> [UInt16] {
        guard let text = name.string else { throw POSIXError(.EILSEQ) }
        return Array(text.utf16)
    }
    private func attributes(_ item: YuzuNTFSItem) throws -> FSItem.Attributes {
        var attr = nb_attr()
        try check(api.nb_getattr!(core, item.ref, item.parent, &attr))
        return try attributes(attr, item: item)
    }
    private func attributes(_ attr: nb_attr, item supplied: YuzuNTFSItem? = nil, writableSnapshot: Bool? = nil) throws -> FSItem.Attributes {
        let result = FSItem.Attributes()
        result.type = attr.type == NB_DIR ? .directory : attr.type == NB_SYMLINK ? .symlink : .file
        result.mode = attr.type == NB_DIR ? 0o755 : 0o644
        result.uid = getuid(); result.gid = getgid()
        result.linkCount = attr.nlink
        result.size = attr.size; result.allocSize = attr.alloc_size
        result.fileID = try id(attr.ref); result.parentID = try id(attr.parent_ref)
        result.flags = attr.ntfs_attrs & 2 != 0 ? UInt32(UF_HIDDEN) : 0
        let item = supplied ?? items.existing(ref: attr.ref)
        let eligible = item?.inhibitsKernelIO ?? (attr.type != NB_FILE || Self.inhibitsIO(flags: attr.flags, writable: writableSnapshot ?? effectivelyWritable()))
        item?.inhibitsKernelIO = eligible
        result.inhibitKernelOffloadedIO = eligible
        result.modifyTime = time(attr.mtime); result.changeTime = time(attr.ctime)
        result.accessTime = time(attr.atime); result.birthTime = time(attr.crtime)
        return result
    }
    private func time(_ ticks: Int64) -> timespec {
        let seconds = ticks / 10_000_000 - 11_644_473_600
        return timespec(tv_sec: Int(seconds), tv_nsec: Int(ticks % 10_000_000) * 100)
    }
    private func ticks(_ time: timespec) throws -> Int64 {
        guard time.tv_nsec >= 0, time.tv_nsec < 1_000_000_000 else { throw POSIXError(.EINVAL) }
        let (seconds, addOverflow) = Int64(time.tv_sec).addingReportingOverflow(11_644_473_600)
        let (whole, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 10_000_000)
        let (result, fractionOverflow) = whole.addingReportingOverflow(Int64(time.tv_nsec / 100))
        guard !addOverflow, !multiplyOverflow, !fractionOverflow else { throw POSIXError(.EINVAL) }
        return result
    }
    private func apply(_ request: FSItem.SetAttributesRequest, to item: YuzuNTFSItem) throws {
        var a = nb_attr(), valid: UInt32 = 0
        if request.isValid(.size) {
            var current = nb_attr(); try check(api.nb_getattr!(core, item.ref, item.parent, &current))
            if !Self.allowsWrite(flags: current.flags) { throw POSIXError(.EPERM) }
            if current.type == NB_FILE { a.size = request.size; valid |= UInt32(NB_SET_SIZE) }
        }
        if request.isValid(.modifyTime) { a.mtime = try ticks(request.modifyTime); valid |= UInt32(NB_SET_MTIME) }
        if request.isValid(.accessTime) { a.atime = try ticks(request.accessTime); valid |= UInt32(NB_SET_ATIME) }
        if request.isValid(.birthTime) { a.crtime = try ticks(request.birthTime); valid |= UInt32(NB_SET_CRTIME) }
        if valid != 0 { try check(api.nb_setattr!(core, item.ref, &a, valid)) }
        for attribute: FSItem.Attribute in [.size, .modifyTime, .accessTime, .birthTime] where request.isValid(attribute) {
            request.consumedAttributes.insert(attribute)
        }
    }
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping ((any Error)?) -> Void) {
        do {
            try serial {
                _ = try node(item)
                if modes.contains(.write) {
                    guard effectivelyWritable() else { throw POSIXError(.EROFS) }
                    var a = nb_attr(); try check(api.nb_getattr!(core, node(item).ref, node(item).parent, &a))
                    if !Self.allowsWrite(flags: a.flags) { throw POSIXError(.EPERM) }
                }
            }
            reply(nil)
        } catch { reply(error) }
    }
    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping ((any Error)?) -> Void) {
        // The bridge owns no per-open handle; FSKit owns cached data and close.
        do { try serial { _ = try node(item) }; reply(nil) } catch { reply(error) }
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
            try serial {
                guard core == nil else { throw POSIXError(.EBUSY) }
                var dev = device.blockdev
                try check(api.nb_mount!(&dev, writable ? 1 : 0, &core))
                rootRef = api.nb_root_ref!(core)
                terminalReadOnly = false
                if var status = sharedStatus {
                    var actual = nb_stat()
                    if api.nb_statfs!(core, &actual) != 0 || actual.read_only != 0 {
                        status.writable = false
                        if status.reason == .writable { status.reason = .engineError }
                    }
                    sharedStatus = status; publishStatus()
                }
                do { try publish(rootRef, parent: rootRef) { reply($0, nil) } }
                catch { discardCore(); throw error }
            }
        } catch { reply(nil, error) }
    }
    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        serial {
            device.metadataActive = true
            guard writable, checkpointTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.bluecoral.yuzuntfs.checkpoint"))
            timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.serial {
                    guard let core = self.core, self.effectivelyWritable() else { return }
                    let error = self.api.nb_sync!(core)
                    if error != 0 {
                        self.terminalReadOnly = true
                        Self.p0Log.error("periodic checkpoint failed errno=\(error)")
                    }
                }
            }
            checkpointTimer = timer
            timer.resume()
        }
        reply(nil)
    }
    func unmount(replyHandler reply: @escaping () -> Void) {
        serial {
            checkpointTimer?.cancel()
            checkpointTimer = nil
            if let core { _ = api.nb_sync!(core); _ = api.nb_unmount!(core); self.core = nil }
            withdrawStatusLocked()
        }
        reply()
    }
    func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        // Normal macOS eject delivers deactivate, not necessarily unloadResource.
        serial { discardCore(); withdrawStatusLocked() }
        reply(nil)
    }
    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        do { try serial { try check(api.nb_sync!(core)) }; reply(nil) } catch { reply(error) }
    }
    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        do {
            let node = try node(item)
            try node.normal { serial {
                let clear = { self.items.forget(node) }
                if #available(macOS 27, *) { _ = item.tryReclaim(clear) } else { Self.reclaimLegacy(node, table: self.items) }
            } }
            reply(nil)
        } catch { reply(error) }
    }
    func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        do {
            try serial {
                let nameUnits = try units(name); var a = nb_attr()
                try check(api.nb_lookup!(core, node(directory).ref, nameUnits, nameUnits.count, &a))
                try publish(a.ref, parent: a.parent_ref) { reply($0, name, nil) }
            }
        } catch { reply(nil, nil, error) }
    }
    func getAttributes(_ request: FSItem.GetAttributesRequest, of item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        do { let a = try serial { try attributes(node(item)) }; reply(a, nil) } catch { reply(nil, error) }
    }
    func setAttributes(_ request: FSItem.SetAttributesRequest, on item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        do { let node = try node(item)
            #if DEBUG
            beforeSizeLock?()
            #endif
            let a = try node.changingSize { try serial {
                guard effectivelyWritable() else { throw POSIXError(.EROFS) }
                if request.isValid(.size) {
                    var current = nb_attr()
                    try check(api.nb_getattr!(core, node.ref, node.parent, &current))
                    try node.checkShrink(to: request.size, currentSize: current.size)
                }
                try apply(request, to: node)
                return try attributes(node)
            } }
            reply(a, nil)
        } catch { reply(nil, error) }
    }
    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes request: FSItem.SetAttributesRequest, replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        do {
            try serial {
                guard effectivelyWritable() else { throw POSIXError(.EROFS) }
                let parent = try node(directory)
                guard type == .file || type == .directory else { throw POSIXError(.ENOTSUP) }
                if request.isValid(.size), request.size > UInt64(Int64.max) { throw POSIXError(.EFBIG) }
                var a = nb_attr(); let u = try units(name)
                try check(api.nb_create!(core, node(directory).ref, u, u.count, UInt32(type == .directory ? NB_DIR : NB_FILE), &a))
                parent.version &+= 1
                do {
                    try publish(a.ref, parent: a.parent_ref, prepare: { item in
                        try apply(request, to: item)
                    }) { reply($0, name, nil) }
                } catch {
                    let rollback = api.nb_remove!(core, parent.ref, u, u.count)
                    if rollback == 0 { parent.version &+= 1 }
                    else { throw POSIXError(.EIO) }
                    throw error
                }
            }
        } catch { reply(nil, nil, error) }
    }
    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        do { _ = try node(item); try serial {
            guard effectivelyWritable() else { throw POSIXError(.EROFS) }
            let parent = try node(directory)
            let u = try units(name); try check(api.nb_remove!(core, parent.ref, u, u.count)); parent.version &+= 1
        }; reply(nil) } catch { reply(error) }
    }
    func renameItem(_ item: FSItem, inDirectory source: FSItem, named old: FSFileName, to new: FSFileName, inDirectory destination: FSItem, overItem: FSItem?, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        do {
            let item = try node(item), source = try node(source), destination = try node(destination)
            _ = try overItem.map { try node($0) }
            try serial {
            guard effectivelyWritable() else { throw POSIXError(.EROFS) }
            let a = try units(old), b = try units(new)
            try check(api.nb_rename!(core, node(source).ref, a, a.count, node(destination).ref, b, b.count))
            item.parent = destination.ref; source.version &+= 1; destination.version &+= 1
        }; reply(new, nil) } catch { reply(nil, error) }
    }
    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes request: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        do {
            let version = try serial {
                let item = try node(directory)
                guard verifier.rawValue == 0 || verifier.rawValue == item.version else { throw POSIXError(.ESTALE) }
                if request == nil {
                    if cookie.rawValue == 0 {
                        if !(try packer.packEntry(name: FSFileName(string: "."), itemType: .directory, itemID: id(item.ref), nextCookie: FSDirectoryCookie(rawValue: 1), attributes: nil)) { return item.version }
                    }
                    if cookie.rawValue <= 1 {
                        if !(try packer.packEntry(name: FSFileName(string: ".."), itemType: .directory, itemID: id(item.parent), nextCookie: FSDirectoryCookie(rawValue: 2), attributes: nil)) { return item.version }
                    }
                }
                // One admission snapshot per serialized batch, not a statfs
                // and fault-hook filesystem lookup for every child.
                let context = Enumeration(volume: self, packer: packer, attributes: request != nil, writable: effectivelyWritable())
                try check(api.nb_readdir!(core, item.ref, cookie.rawValue > 2 ? cookie.rawValue - 2 : 0, { opaque, name, count, attr, next in
                    let c = Unmanaged<Enumeration>.fromOpaque(opaque!).takeUnretainedValue()
                    let a = attr!.pointee
                    let text = String(decoding: UnsafeBufferPointer(start: name, count: count), as: UTF16.self)
                    do {
                        let identifier = try c.volume.id(a.ref)
                        let cookie = try YuzuNTFSBoundary.adding(next, 2)
                        let attributes = c.attributes ? try c.volume.attributes(a, writableSnapshot: c.writable) : nil
                        return c.packer.packEntry(name: FSFileName(string: text), itemType: a.type == NB_DIR ? .directory : .file,
                            itemID: identifier, nextCookie: FSDirectoryCookie(rawValue: cookie), attributes: attributes) ? 0 : 1
                    } catch { c.error = error; return 1 }
                }, Unmanaged.passUnretained(context).toOpaque()))
                if let error = context.error { throw error }
                return item.version
            }
            reply(FSDirectoryVerifier(rawValue: version), nil)
        } catch { reply(verifier, error) }
    }
    private final class Enumeration {
        let volume: YuzuNTFSVolume, packer: FSDirectoryEntryPacker
        let attributes: Bool, writable: Bool
        var error: (any Error)?
        init(volume: YuzuNTFSVolume, packer: FSDirectoryEntryPacker, attributes: Bool, writable: Bool) {
            self.volume = volume; self.packer = packer; self.attributes = attributes; self.writable = writable
        }
    }
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        Self.p0Log.info("bufferedRead offset=\(offset) length=\(length)")
        do {
            guard Self.validRange(offset: offset, length: length) else { throw POSIXError(.EINVAL) }
            var got = 0
            try node(item).normal { try serial { try buffer.withUnsafeMutableBytes { bytes in
                try check(api.nb_read!(core, node(item).ref, UInt64(offset), bytes.baseAddress, min(length, bytes.count), &got))
            } } }
            reply(got, nil)
        } catch { reply(0, error) }
    }
    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        do {
            guard Self.validRange(offset: offset, length: contents.count) else { throw POSIXError(.EINVAL) }
            try node(item).normal { try serial {
                guard effectivelyWritable() else { throw POSIXError(.EROFS) }
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
        Self.p0Log.info("blockmapFile offset=\(offset) length=\(length) write=\(flags.contains(.write)) operationID=\(operationID.rawValue)")
        guard Self.validRange(offset: offset, length: length) else { reply(POSIXError(.EINVAL)); return }
        guard let item = file as? YuzuNTFSItem else { reply(POSIXError(.EINVAL)); return }
        // Only explicit writes need a lease to protect their extents from
        // shrink. Read mappings can be retained without a completeIO callback.
        let leasesWrite = flags.contains(.write) && operationID != .unspecified
        item.io.lock()
        if flags.contains(.write) && item.operation != nil && item.operation != operationID {
            item.io.unlock(); reply(POSIXError(.EBUSY)); return
        }
        do {
            if leasesWrite { item.operation = operationID }
            try serial {
                if !effectivelyWritable() && (flags.contains(.write) || length > 0) {
                    if flags.contains(.write) { throw POSIXError(.EROFS) }
                    var attr = nb_attr()
                    try check(api.nb_getattr!(core, item.ref, item.parent, &attr))
                    // Never promote/zero a resident or partial-VDL item after
                    // the latch. Its already-published inhibition stays fixed.
                    if attr.flags & UInt32(NB_RESIDENT | NB_UNALIGNED_VDL) != 0 { throw POSIXError(.EROFS) }
                }
                let sector = UInt64(device.blockdev.sector_size)
                guard sector > 0 else { throw POSIXError(.EINVAL) }
                // The kernel retains READ maps for later writeback. Cover
                // whole device sectors on both paths; byte-sized extents can
                // read correctly yet corrupt a subsequent partial-sector write.
                let mappingOffset = UInt64(offset) / sector * sector
                let requestEnd = try YuzuNTFSBoundary.adding(UInt64(offset), UInt64(length))
                let mappingEnd = length == 0 ? mappingOffset : try YuzuNTFSBoundary.adding(requestEnd, sector - 1) / sector * sector
                _ = try YuzuNTFSBoundary.offset(mappingEnd)
                let mappingLength = mappingEnd - mappingOffset
                var packedOffset = mappingOffset
                // io remains locked: no write can acquire/release a lease
                // between this decision and partial-VDL mapping/zeroing.
                try YuzuNTFSMapping.map(api: api, core: core, ref: item.ref, offset: mappingOffset, length: mappingLength,
                                       write: flags.contains(.write), preservingWrite: item.operation != nil) { extents in
                    try device.purge(extents)
                    if leasesWrite { item.extents.append(contentsOf: extents) }
                    for extent in extents {
                        let end = try YuzuNTFSBoundary.adding(extent.logical, extent.length)
                        _ = try YuzuNTFSBoundary.offset(end)
                        _ = try YuzuNTFSBoundary.offset(YuzuNTFSBoundary.adding(extent.physical, extent.length))
                        guard extent.logical == packedOffset, extent.length > 0,
                              extent.logical % sector == 0, extent.length % sector == 0,
                              extent.kind == NB_EXT_HOLE || extent.physical % sector == 0 else { throw POSIXError(.EINVAL) }
                        var done: UInt64 = 0
                        while done < extent.length {
                            let logicalValue = try YuzuNTFSBoundary.adding(extent.logical, done)
                            let chunk = min(extent.length - done, (UInt64(UInt32.max) & ~UInt64(4095)) - logicalValue % sector)
                            let zero = extent.kind == NB_EXT_HOLE || (extent.kind == NB_EXT_UNINIT && !flags.contains(.write))
                            let logical = try YuzuNTFSBoundary.offset(logicalValue)
                            let physical = try YuzuNTFSBoundary.offset(YuzuNTFSBoundary.adding(extent.physical, done))
                            guard let resource = device.extentResource else { throw POSIXError(.ENODEV) }
                            Self.p0Log.info("packExtent ref=\(item.ref) operationID=\(operationID.rawValue) logical=\(logical) physical=\(physical) length=\(chunk) zeroFill=\(zero)")
                            if !packer.packExtent(resource: resource, type: zero ? .zeroFill : .data,
                                logicalOffset: logical, physicalOffset: physical, length: Int(chunk)) { return false }
                            done += chunk
                        }
                        packedOffset = end
                    }
                    return true
                }
            }
            item.io.unlock(); reply(nil)
        } catch {
            if leasesWrite { item.finishMapping(operationID) }
            item.io.unlock(); reply(error)
        }
    }
    // SDK 27 incorrectly annotates status nonnull; its own contract specifies
    // nil for success. Keep Optional to avoid trapping on successful I/O.
    func completeIO(for file: FSItem, offset: off_t, length: Int, status: (any Error)?, flags: FSCompleteIOFlags, operationID: FSOperationID, replyHandler reply: @escaping ((any Error)?) -> Void) {
        Self.p0Log.info("completeIO offset=\(offset) length=\(length) write=\(flags.contains(.write)) operationID=\(operationID.rawValue)")
        guard Self.validRange(offset: offset, length: length) else { reply(POSIXError(.EINVAL)); return }
        guard let item = file as? YuzuNTFSItem else { reply(POSIXError(.EINVAL)); return }
        do {
            try item.completing(operationID) { try serial {
                if flags.contains(.write) && !effectivelyWritable() { throw POSIXError(.EROFS) }
                var cachedExtents: [nb_extent] = []
                let tracked = operationID != .unspecified && item.operation == operationID
                if !tracked {
                    try YuzuNTFSMapping.query(api: api, core: core, ref: item.ref, offset: UInt64(offset), length: UInt64(length)) {
                        cachedExtents.append(contentsOf: $0); return true
                    }
                }
                try device.purge(tracked ? item.extents : cachedExtents)
                try check(api.nb_complete_io!(core, item.ref, UInt64(offset), UInt64(length), status.map { YuzuNTFSBoundary.errorCode($0) } ?? 0, flags.contains(.write) ? 1 : 0))
                try device.purge(tracked ? item.extents : cachedExtents)
            } }
            reply(nil)
        } catch { reply(error) }
    }
    func createFile(name: FSFileName, in directory: FSItem, attributes: FSItem.SetAttributesRequest, packer: FSExtentPacker, replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) { createItem(named: name, type: .file, inDirectory: directory, attributes: attributes, replyHandler: replyHandler) }
    func lookupItem(name: FSFileName, in directory: FSItem, packer: FSExtentPacker, replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) { lookupItem(named: name, inDirectory: directory, replyHandler: replyHandler) }
    func createSymbolicLink(named: FSFileName, inDirectory: FSItem, attributes: FSItem.SetAttributesRequest, linkContents: FSFileName, replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) { replyHandler(nil, nil, POSIXError(.ENOTSUP)) }
    func createLink(to item: FSItem, named: FSFileName, inDirectory: FSItem, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) { replyHandler(nil, POSIXError(.ENOTSUP)) }
    func readSymbolicLink(_ item: FSItem, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) { replyHandler(nil, POSIXError(.ENOTSUP)) }
}
