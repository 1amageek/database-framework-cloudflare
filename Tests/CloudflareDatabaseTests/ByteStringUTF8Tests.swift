@testable import CloudflareDatabase
import DatabaseTypes
import Testing

@Suite("ByteString UTF-8 construction")
struct ByteStringUTF8Tests {
    @Test("copies complete Unicode scalars")
    func copiesCompleteUnicodeScalars() {
        let bytes = ByteString.copyingUTF8("Aé日")
        #expect(bytes == ByteString([0x41, 0xC3, 0xA9, 0xE6, 0x97, 0xA5]))
    }

    @Test("respects the byte limit")
    func respectsByteLimit() {
        let bytes = ByteString.copyingUTF8(
            "database",
            maximumByteCount: 4
        )
        #expect(bytes == ByteString([0x64, 0x61, 0x74, 0x61]))
    }

    @Test("never writes a partial Unicode scalar")
    func neverWritesPartialUnicodeScalar() {
        #expect(ByteString.copyingUTF8("é", maximumByteCount: 1).isEmpty)
        #expect(
            ByteString.copyingUTF8("Aé", maximumByteCount: 2)
                == ByteString([0x41])
        )
        #expect(
            ByteString.copyingUTF8("A😀B", maximumByteCount: 5)
                == ByteString([0x41, 0xF0, 0x9F, 0x98, 0x80])
        )
    }
}
