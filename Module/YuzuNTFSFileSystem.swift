// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import FSKit
import NTFSProbe

final class YuzuNTFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
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
            let sector = try NTFSBootSector.parse(UnsafeRawBufferPointer(start: buffer, count: actual))
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
            containerStatus = .ready
            replyHandler(volume, nil)
        } catch { replyHandler(nil, error) }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions,
                        replyHandler: @escaping ((any Error)?) -> Void) {
        containerStatus = .notReady(status: POSIXError(.ENOTCONN))
        replyHandler(nil)
    }
}
