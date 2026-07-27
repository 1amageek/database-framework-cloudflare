import DatabaseTypes

extension ByteString {
    static func copyingUTF8(
        _ string: String,
        maximumByteCount: Int = .max
    ) -> ByteString {
        precondition(maximumByteCount >= 0)
        var byteCount = 0
        for scalar in string.unicodeScalars {
            let scalarByteCount: Int
            switch scalar.value {
            case 0...0x7F: scalarByteCount = 1
            case 0x80...0x7FF: scalarByteCount = 2
            case 0x800...0xFFFF: scalarByteCount = 3
            default: scalarByteCount = 4
            }
            guard scalarByteCount <= maximumByteCount - byteCount else {
                break
            }
            byteCount += scalarByteCount
        }
        return ByteString.copying(count: byteCount) { destination in
            var index = 0
            for byte in string.utf8 {
                guard index < byteCount else {
                    break
                }
                destination[index] = byte
                index += 1
            }
        }
    }
}
