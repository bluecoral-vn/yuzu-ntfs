// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import NTFSBridge
import NTFSProbe
import EngineE2

/// Check-only maintenance: never repairs, replays a journal or clears dirty flags.
/// All options (including fsck's -y) deliberately have the same read-only semantics.
enum YuzuNTFSMaintenance {
    private static let queue = DispatchQueue(label: "com.bluecoral.vn.yuzuntfs.maintenance")

    static func start(on queue: DispatchQueue = queue,
                      check: @escaping @Sendable () -> (any Error)?,
                      completion: @escaping @Sendable (Progress, (any Error)?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        // FSKit must receive an unfinished Progress and a later didComplete signal.
        // Inline/pre-completed progress can wedge the check connector and Disk Arbitration.
        queue.async {
            let failure = progress.isCancelled ? POSIXError(.ECANCELED) : check()
            progress.completedUnitCount = 1
            completion(progress, failure)
        }
        return progress
    }

    static func requireClean(_ state: nb_state) throws {
        guard state != NB_CLEAN else { return }
        let reason: String
        switch state {
        case NB_HIBERNATED: reason = "Windows is hibernated. Resume Windows and shut it down completely."
        case NB_FAST_STARTUP: reason = "Windows Fast Startup is active. Disable it and shut Windows down completely."
        case NB_DIRTY_LOG: reason = "The NTFS journal needs recovery. Run chkdsk in Windows and safely eject the drive."
        case NB_DIRTY_FLAG: reason = "NTFS is marked dirty. Run chkdsk in Windows and safely eject the drive."
        case NB_BITLOCKER: reason = "BitLocker is unsupported. Unlock the drive in Windows."
        default: reason = "This NTFS format is unsupported. Check the drive in Windows."
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS), userInfo: [NSLocalizedDescriptionKey: reason + " Yuzu NTFS performs no repairs."])
    }

    static func verify(device: inout nb_blockdev) throws {
        // Defence in depth: neither probe nor mountability verification can write,
        // even if the engine's implementation changes in a future release.
        var readOnly = device
        readOnly.write = { _, _, _, _ in EROFS }
        readOnly.flush = { _ in 0 }
        guard let read = readOnly.read else { throw POSIXError(.EIO) }
        var boot = [UInt8](repeating: 0, count: max(512, Int(readOnly.sector_size)))
        let code = read(readOnly.ctx, 0, &boot, boot.count)
        guard code == 0 else { throw posix(code) }
        _ = try boot.withUnsafeBytes { try NTFSBootSector.parse($0) }

        let api = nb_engine_e2()!.pointee
        var state = NB_UNSUPPORTED
        let probe = api.nb_probe_state!(&readOnly, &state)
        guard probe == 0 else { throw posix(probe) }
        try requireClean(state)
        var core: OpaquePointer?
        let mounted = api.nb_mount!(&readOnly, 0, &core)
        guard mounted == 0, let core else { throw posix(mounted == 0 ? EIO : mounted) }
        // Discard this read-only checker, never sync or perform repair teardown.
        defer { _ = api.nb_dispose!(core) }
        let root = api.nb_root_ref!(core)
        var attributes = nb_attr()
        let metadata = api.nb_getattr!(core, root, root, &attributes)
        guard metadata == 0 else { throw posix(metadata) }
        guard root == 5, attributes.type == NB_DIR else { throw POSIXError(.EIO) }
    }

    private static func posix(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey:
            "Read-only NTFS boot/MFT verification failed (\(code)). Check this drive in Windows. Yuzu NTFS performs no repairs."])
    }
}
