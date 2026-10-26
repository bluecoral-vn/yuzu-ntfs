// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import FSKit
import NTFSProbe

final class YuzuNTFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    private let resourceLock = NSLock()
    private var lastResource: FSBlockDeviceResource?
    private weak var lastVolume: YuzuNTFSVolume?

    private struct CheckContext: @unchecked Sendable {
        let resource: FSBlockDeviceResource?
        let volume: YuzuNTFSVolume?
        func validate() throws {
            guard let resource, !resource.isRevoked else { throw POSIXError(.ENODEV) }
            _ = try YuzuNTFSGeometry(blockSize: resource.blockSize, blockCount: resource.blockCount,
                                    physicalBlockSize: resource.physicalBlockSize)
            try volume?.withUnactivatedResource {}
        }
        func verify() throws {
            guard let resource else { throw POSIXError(.ENODEV) }
            let check = {
                let adapter = try YuzuNTFSDevice(resource)
                var device = adapter.blockdev
                try withExtendedLifetime(adapter) { try YuzuNTFSMaintenance.verify(device: &device) }
            }
            if let volume { try volume.withUnactivatedResource(check) }
            else { try check() }
        }
    }

    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let device = resource as? FSBlockDeviceResource else {
            replyHandler(.notRecognized, nil)
            return
        }
        do {
            let geometry = try YuzuNTFSGeometry(blockSize: device.blockSize, blockCount: device.blockCount, physicalBlockSize: device.physicalBlockSize)
            let count = geometry.probeLength
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 4096)
            defer { buffer.deallocate() }
            let actual = try device.read(into: UnsafeMutableRawBufferPointer(start: buffer, count: count),
                                         startingAt: 0, length: count)
            guard actual >= 0, actual <= count else { throw POSIXError(.EIO) }
            if NTFSBootSector.isBitLocker(UnsafeRawBufferPointer(start: buffer, count: actual)) {
                if let directory = BetaPolicy.directory {
                    try? VolumeStatus(serial: 0, device: device.bsdName, writable: false, reason: .bitlocker).write(at: directory)
                }
                replyHandler(.notRecognized, nil)
                return
            }
            let sector = try NTFSBootSector.parse(UnsafeRawBufferPointer(start: buffer, count: actual))
            resourceLock.withLock { lastResource = device }
            replyHandler(.usable(name: "NTFS", containerID: FSContainerIdentifier(uuid: sector.volumeUUID)), nil)
        } catch is NTFSProbeError {
            replyHandler(.notRecognized, nil)
        } catch {
            replyHandler(nil, error)
        }
    }

    func loadResource(resource: FSResource, options: FSTaskOptions,
                      replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let device = resource as? FSBlockDeviceResource else { replyHandler(nil, POSIXError(.ENODEV)); return }
        do {
            let geometry = try YuzuNTFSGeometry(blockSize: device.blockSize, blockCount: device.blockCount, physicalBlockSize: device.physicalBlockSize)
            let count = max(4096, geometry.probeLength)
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 4096)
            defer { buffer.deallocate() }
            let actual = try device.read(into: UnsafeMutableRawBufferPointer(start: buffer, count: count), startingAt: 0, length: count)
            guard actual >= 0, actual <= count else { throw POSIXError(.EIO) }
            let boot = try NTFSBootSector.parse(UnsafeRawBufferPointer(start: buffer, count: actual))
            let volume = try YuzuNTFSVolume(device: device, boot: boot, readOnly: options.taskOptions.contains("--rdonly"))
            resourceLock.withLock { lastResource = device; lastVolume = volume }
            containerStatus = .ready
            replyHandler(volume, nil)
        } catch { replyHandler(nil, error) }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions,
                        replyHandler: @escaping ((any Error)?) -> Void) {
        resourceLock.withLock { lastResource = nil; lastVolume = nil }
        containerStatus = .notReady(status: POSIXError(.ENOTCONN))
        replyHandler(nil)
    }
}

extension YuzuNTFSFileSystem: FSManageableResourceMaintenanceOperations {
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        let context = resourceLock.withLock { CheckContext(resource: lastResource, volume: lastVolume) }
        return try YuzuNTFSMaintenance.start(validate: context.validate, check: {
            task.logMessage("Checking NTFS boot/MFT and clean state, read-only. Repair options are not supported; no repairs will be performed.")
            do { try context.verify(); task.logMessage("Read-only NTFS check passed."); return nil }
            catch { task.logMessage(error.localizedDescription); return error }
        }, completion: { _, failure in task.didComplete(error: failure) })
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw POSIXError(.ENOTSUP)
    }
}
