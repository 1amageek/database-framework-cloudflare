@testable import CloudflareDatabase
import DatabaseTypes
import Synchronization
import Testing

@Suite("Invocation payload ownership")
struct InvocationPayloadOwnerTests {
    @Test("ByteString borrows the runtime allocation and releases it once")
    func borrowsAndReleasesRuntimeAllocation() {
        let releasedPayloads = Mutex<[(address: UInt, count: Int)]>([])
        let allocation = UnsafeMutableRawPointer.allocate(
            byteCount: 3,
            alignment: MemoryLayout<UInt8>.alignment
        )
        allocation.storeBytes(of: UInt8(0x10), toByteOffset: 0, as: UInt8.self)
        allocation.storeBytes(of: UInt8(0x20), toByteOffset: 1, as: UInt8.self)
        allocation.storeBytes(of: UInt8(0x30), toByteOffset: 2, as: UInt8.self)
        let address = UInt(bitPattern: allocation)

        do {
            let bytes = ByteString(
                retaining: InvocationPayloadOwner(
                    address: address,
                    count: 3,
                    release: { releasedAddress, releasedCount in
                        releasedPayloads.withLock {
                            $0.append((releasedAddress, releasedCount))
                        }
                        UnsafeMutableRawPointer(
                            bitPattern: releasedAddress
                        )?.deallocate()
                    }
                )
            )

            bytes.withUnsafeBytes { borrowedBytes in
                #expect(
                    borrowedBytes.baseAddress.map(UInt.init(bitPattern:))
                        == address
                )
                #expect(Array(borrowedBytes) == [0x10, 0x20, 0x30])
            }
            #expect(releasedPayloads.withLock { $0.isEmpty })
        }

        let releases = releasedPayloads.withLock { $0 }
        #expect(releases.count == 1)
        #expect(releases[0].address == address)
        #expect(releases[0].count == 3)
    }
}
