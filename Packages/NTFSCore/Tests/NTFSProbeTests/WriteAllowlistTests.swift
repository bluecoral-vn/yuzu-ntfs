// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import NTFSProbe

@Test func writeAllowlistFailsClosed() {
    #expect(!WriteAllowlist.permits(serial: 0x1234, contents: nil))
    #expect(!WriteAllowlist.permits(serial: 0x1234, contents: ""))
    #expect(!WriteAllowlist.permits(serial: 0x1234, contents: "0000000000001235\n"))
    #expect(!WriteAllowlist.permits(serial: 0x1234, contents: "1234\n"))
    #expect(!WriteAllowlist.permits(serial: 0x1234, contents: "0000000000001234\ngarbage\n"))
    #expect(WriteAllowlist.permits(serial: 0x1234, contents: "0000000000001234\nFFFFFFFFFFFFFFFF\n"))
    #expect(WriteAllowlist.permits(serial: UInt64.max, contents: "ffffffffffffffff\n"))
}
