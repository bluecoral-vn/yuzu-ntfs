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
        let length = max(512, device.blockSize, device.physicalBlockSize)
        guard let count = Int(exactly: length) else {
            replyHandler(nil, POSIXError(.EOVERFLOW))
            return
        }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 4096)
        defer { buffer.deallocate() }
        do {
            let actual = try device.read(into: UnsafeMutableRawBufferPointer(start: buffer, count: count),
                                         startingAt: 0, length: count)
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
        replyHandler(nil, POSIXError(.ENOTSUP))
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions,
                        replyHandler: @escaping ((any Error)?) -> Void) {
        replyHandler(nil)
    }
}
