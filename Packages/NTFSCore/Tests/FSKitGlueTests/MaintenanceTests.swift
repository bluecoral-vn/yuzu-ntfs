// SPDX-License-Identifier: GPL-2.0-only
import Darwin
import Foundation
import Testing
import NTFSBridge
import EngineE2
import FSKit
import ObjectiveC
@testable import FSKitGlue

private final class MaintenanceObservation: @unchecked Sendable {
    let lock = NSLock()
    var calls = 0
    let startingThread = Thread.current
    var callsOnStartingThread = 0
    var sawFinishedProgress = false
    var error: (any Error)?
    let completed = DispatchSemaphore(value: 0)
    func finish(_ progress: Progress, _ error: (any Error)?) {
        lock.withLock {
            calls += 1; sawFinishedProgress = progress.isFinished; self.error = error
            if Thread.current == startingThread { callsOnStartingThread += 1 }
        }
        completed.signal()
    }
}

struct MaintenanceTests {
    @Test func startupFailureReturnsNoProgressAndNeverCompletes() {
        let observation = MaintenanceObservation()
        var progress: Progress?
        #expect(throws: POSIXError.self) {
            progress = try YuzuNTFSMaintenance.start(validate: { throw POSIXError(.ENODEV) },
                check: { Issue.record("Check ran after a startup failure"); return nil }, completion: observation.finish)
        }
        #expect(progress == nil)
        #expect(observation.lock.withLock { observation.calls } == 0)
    }
    @Test func productionStartRejectsMissingResourceBeforeUsingTask() throws {
        let filesystem = YuzuNTFSFileSystem()
        // No task messages/completion are legal on this synchronous-throw path.
        let task = class_createInstance(FSTask.self, 0) as! FSTask
        let options = class_createInstance(FSTaskOptions.self, 0) as! FSTaskOptions
        #expect(throws: POSIXError.self) { _ = try filesystem.startCheck(task: task, options: options) }
    }
    @Test func productionQueueCompletesExactlyOnceWithoutCallingThreadReentrancy() throws {
        let observation = MaintenanceObservation()
        let progress = try YuzuNTFSMaintenance.start(check: { nil }, completion: observation.finish)
        #expect(progress.totalUnitCount == 1)
        #expect(observation.completed.wait(timeout: .now() + 3) == .success)
        #expect(observation.lock.withLock {
            observation.calls == 1 && observation.sawFinishedProgress && observation.error == nil && observation.callsOnStartingThread == 0
        })
    }
    @Test func failedCheckStillCompletesProgressAndTask() throws {
        let observation = MaintenanceObservation()
        let progress = try YuzuNTFSMaintenance.start(check: { POSIXError(.EROFS) }, completion: observation.finish)
        #expect(observation.completed.wait(timeout: .now() + 3) == .success)
        #expect(progress.isFinished)
        #expect(observation.lock.withLock { observation.calls == 1 && (observation.error as? POSIXError)?.code == .EROFS })
    }
    @Test func everyUnsafeStateFailsWithWindowsInstructions() throws {
        try YuzuNTFSMaintenance.requireClean(NB_CLEAN)
        for state in [NB_HIBERNATED, NB_FAST_STARTUP, NB_DIRTY_LOG, NB_DIRTY_FLAG, NB_BITLOCKER, NB_UNSUPPORTED] {
            do { try YuzuNTFSMaintenance.requireClean(state); Issue.record("Unsafe state admitted: \(state)") }
            catch { #expect(error.localizedDescription.contains("Windows")) }
        }
    }
    @Test func realCleanCheckUsesOnlyReadsAndVerifiesRootMFT() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let image = root.appendingPathComponent("fixtures/basic-512.img")
        let fd = open(image.path, O_RDONLY)
        try #require(fd >= 0, "Missing fixtures: run scripts/make-fixtures.sh")
        defer { close(fd) }
        var info = Darwin.stat(); try #require(fstat(fd, &info) == 0)
        final class Reads { let fd: Int32; var writes = 0; init(_ fd: Int32) { self.fd = fd } }
        let reads = Reads(fd)
        var device = nb_blockdev(ctx: Unmanaged.passUnretained(reads).toOpaque(), size: UInt64(info.st_size), sector_size: 512,
            read: { ctx, offset, buffer, length in
                let source = Unmanaged<Reads>.fromOpaque(ctx!).takeUnretainedValue()
                return pread(source.fd, buffer, length, off_t(offset)) == length ? 0 : EIO
            }, write: { ctx, _, _, _ in
                Unmanaged<Reads>.fromOpaque(ctx!).takeUnretainedValue().writes += 1; return EROFS
            }, flush: { _ in 0 })
        try YuzuNTFSMaintenance.verify(device: &device)
        #expect(reads.writes == 0)
        device.read = { _, _, buffer, length in memset(buffer, 0, length); return 0 }
        #expect(throws: (any Error).self) { try YuzuNTFSMaintenance.verify(device: &device) }
        #expect(reads.writes == 0)
    }
}
