// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import ObjectiveC
import FSKit
import NTFSBridge
import Testing
@testable import FSKitGlue

private final class TransferState {
    let sector: Int
    var bytes = (0..<65536).map { UInt8(truncatingIfNeeded: $0 * 17 + 3) }
    var reads: [Int] = [], writes: [Int] = [], metadataReads: [Int] = []
    var immediate: [Int] = [], delayed: [Int] = [], flushes = 0
    var shortRead = false
    init(_ sector: Int) { self.sector = sector }
}

private func transferResource(_ state: TransferState) throws -> FSBlockDeviceResource {
    // Exercise the real adapter; supply only the SDK's out-of-process resource
    // boundary, as CompletionTests does for its SDK packer/resource objects.
    let cls: AnyClass = try #require(objc_allocateClassPair(FSBlockDeviceResource.self, "YuzuTransfer\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))", 0))
    let block: @convention(block) (AnyObject) -> UInt64 = { _ in UInt64(state.sector) }
    let count: @convention(block) (AnyObject) -> UInt64 = { _ in UInt64(state.bytes.count / state.sector) }
    try #require(class_addMethod(cls, NSSelectorFromString("blockSize"), imp_implementationWithBlock(block), "Q@:"))
    try #require(class_addMethod(cls, NSSelectorFromString("physicalBlockSize"), imp_implementationWithBlock(block), "Q@:"))
    try #require(class_addMethod(cls, NSSelectorFromString("blockCount"), imp_implementationWithBlock(count), "Q@:"))
    let read: @convention(block) (AnyObject, UnsafeMutableRawPointer, Int64, Int, UnsafeMutableRawPointer?) -> Int = { _, buffer, offset, length, _ in
        state.reads.append(length)
        if state.shortRead { return 0 }
        state.bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!.advanced(by: Int(offset)), byteCount: length) }
        return length
    }
    let write: @convention(block) (AnyObject, UnsafeRawPointer, Int64, Int, UnsafeMutableRawPointer?) -> Int = { _, buffer, offset, length, _ in
        state.writes.append(length)
        state.bytes.withUnsafeMutableBytes { $0.baseAddress!.advanced(by: Int(offset)).copyMemory(from: buffer, byteCount: length) }
        return length
    }
    let metadataRead: @convention(block) (AnyObject, UnsafeMutableRawPointer, Int64, Int, UnsafeMutableRawPointer?) -> Bool = { _, buffer, offset, length, _ in
        state.metadataReads.append(length)
        state.bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!.advanced(by: Int(offset)), byteCount: length) }
        return true
    }
    let immediate: @convention(block) (AnyObject, UnsafeRawPointer, Int64, Int, UnsafeMutableRawPointer?) -> Bool = { _, buffer, offset, length, _ in
        state.immediate.append(length)
        state.bytes.withUnsafeMutableBytes { $0.baseAddress!.advanced(by: Int(offset)).copyMemory(from: buffer, byteCount: length) }
        return true
    }
    let delayed: @convention(block) (AnyObject, UnsafeRawPointer, Int64, Int, UnsafeMutableRawPointer?) -> Bool = { _, buffer, offset, length, _ in
        state.delayed.append(length)
        state.bytes.withUnsafeMutableBytes { $0.baseAddress!.advanced(by: Int(offset)).copyMemory(from: buffer, byteCount: length) }
        return true
    }
    let flush: @convention(block) (AnyObject, UnsafeMutableRawPointer?) -> Bool = { _, _ in state.flushes += 1; return true }
    try #require(class_addMethod(cls, NSSelectorFromString("readInto:startingAt:length:error:"), imp_implementationWithBlock(read), "Q@:^vqQ^v"))
    try #require(class_addMethod(cls, NSSelectorFromString("writeFrom:startingAt:length:error:"), imp_implementationWithBlock(write), "Q@:^vqQ^v"))
    try #require(class_addMethod(cls, NSSelectorFromString("metadataReadInto:startingAt:length:error:"), imp_implementationWithBlock(metadataRead), "B@:^vqQ^v"))
    try #require(class_addMethod(cls, NSSelectorFromString("metadataWriteFrom:startingAt:length:error:"), imp_implementationWithBlock(immediate), "B@:^vqQ^v"))
    try #require(class_addMethod(cls, NSSelectorFromString("delayedMetadataWriteFrom:startingAt:length:error:"), imp_implementationWithBlock(delayed), "B@:^vqQ^v"))
    try #require(class_addMethod(cls, NSSelectorFromString("metadataFlushWithError:"), imp_implementationWithBlock(flush), "B@:^v"))
    objc_registerClassPair(cls)
    let resource = class_createInstance(cls, 0) as! FSBlockDeviceResource
    let descriptor = try #require(class_getInstanceVariable(FSBlockDeviceResource.self, "_fileDescriptor"))
    Unmanaged.passUnretained(resource).toOpaque().advanced(by: ivar_getOffset(descriptor)).storeBytes(of: Int32(-1), as: Int32.self)
    return resource
}

@Test(arguments: [512, 4096]) func preMountAlignedTransfersUseWholeEngineRequest(sector: Int) throws {
    let state = TransferState(sector), resource = try transferResource(state)
    let device = try YuzuNTFSDevice(resource), api = device.blockdev
    var bytes = [UInt8](repeating: 0, count: 8192)
    try #require(api.read!(api.ctx, 4096, &bytes, bytes.count) == 0)
    #expect(bytes == Array(state.bytes[4096..<12288]))
    #expect(state.reads == [8192])
    bytes = [UInt8](repeating: 0x7B, count: 8192)
    try #require(api.write!(api.ctx, 4096, &bytes, bytes.count) == 0)
    #expect(state.writes == [8192])
    #expect(Array(state.bytes[4096..<12288]) == bytes)
    #expect(state.immediate.isEmpty && state.delayed.isEmpty)
    #expect(api.flush!(api.ctx) == 0)
    #expect(state.flushes == 0) // Before mount, no FSKit metadata cache exists.
}

@Test(arguments: [512, 4096]) func mountedMetadataRetainsSectorKeysAndFlushesDelayedWrites(sector: Int) throws {
    let state = TransferState(sector), resource = try transferResource(state)
    let device = try YuzuNTFSDevice(resource), api = device.blockdev
    device.metadataActive = true
    let original = state.bytes
    let payload: [UInt8] = [0x91, 0x92, 0x93]
    try #require(payload.withUnsafeBytes { api.write!(api.ctx, 9, $0.baseAddress, $0.count) } == 0)
    #expect(state.reads.isEmpty && state.writes.isEmpty)
    #expect(state.metadataReads == [sector])
    #expect(state.immediate.isEmpty)
    #expect(state.delayed == [sector])
    #expect(state.bytes.prefix(9) == original.prefix(9))
    #expect(Array(state.bytes[9..<12]) == payload)
    #expect(state.bytes.dropFirst(12) == original.dropFirst(12))
    #expect(api.flush!(api.ctx) == 0)
    #expect(state.flushes == 1)
}

@Test func preMountShortReadFailsWithoutExposingPartialData() throws {
    let state = TransferState(512), resource = try transferResource(state)
    let device = try YuzuNTFSDevice(resource), api = device.blockdev
    state.shortRead = true
    var bytes = [UInt8](repeating: 0, count: 4096)
    #expect(api.read!(api.ctx, 0, &bytes, bytes.count) == EIO)
}
