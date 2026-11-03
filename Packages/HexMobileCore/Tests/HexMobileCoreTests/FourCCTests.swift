import Testing
@testable import HexMobileCore

@Suite("Four-character codes")
struct FourCCTests {
    @Test("The codes seen on a device read as text")
    func deviceCodes() {
        #expect(FourCC.string(for: 2003329396) == "what")
        #expect(FourCC.string(for: 560557684) == "!int")
    }

    @Test("Printable bytes decode in order")
    func byteOrder() {
        #expect(FourCC.string(for: 0x6162_6364) == "abcd")
        // Top byte above ASCII: not text.
        #expect(FourCC.string(for: 0xE1E2_E3E4) == nil)
    }

    @Test("Plain numbers and out-of-range values are not text")
    func notText() {
        #expect(FourCC.string(for: 0) == nil)
        #expect(FourCC.string(for: 2) == nil)
        #expect(FourCC.string(for: -50) == nil)
        #expect(FourCC.string(for: -1) == nil)
        #expect(FourCC.string(for: Int(UInt32.max) + 1) == nil)
        #expect(FourCC.string(for: Int.min) == nil)
        // A control character inside an otherwise printable code.
        #expect(FourCC.string(for: 0x6100_6263) == nil)
    }

    @Test("Spaces are printable")
    func spaces() {
        #expect(FourCC.string(for: 0x6162_2020) == "ab  ")
    }
}
