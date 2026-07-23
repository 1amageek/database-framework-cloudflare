@testable import CloudflareDatabase
import DatabaseValue
import Testing

@Suite("DatabaseBytes UTF-8 construction")
struct DatabaseBytesUTF8Tests {
    @Test("UTF-8 construction writes directly into final owned storage")
    func copiesUTF8IntoOwnedStorage() {
        let bytes = DatabaseBytes.copyingUTF8("Aé日")

        #expect(bytes == DatabaseBytes([0x41, 0xC3, 0xA9, 0xE6, 0x97, 0xA5]))
    }

    @Test("UTF-8 construction enforces its byte limit")
    func enforcesMaximumByteCount() {
        let bytes = DatabaseBytes.copyingUTF8(
            "database",
            maximumByteCount: 4
        )

        #expect(bytes == DatabaseBytes([0x64, 0x61, 0x74, 0x61]))
    }

    @Test("UTF-8 construction never splits a Unicode scalar")
    func preservesScalarBoundaries() {
        #expect(
            DatabaseBytes.copyingUTF8("é", maximumByteCount: 1).isEmpty
        )
        #expect(
            DatabaseBytes.copyingUTF8("Aé", maximumByteCount: 2)
                == DatabaseBytes([0x41])
        )
        #expect(
            DatabaseBytes.copyingUTF8("A😀B", maximumByteCount: 5)
                == DatabaseBytes([0x41, 0xF0, 0x9F, 0x98, 0x80])
        )
    }
}
