// swift-tools-version: 6.4
import Foundation
import PackageDescription

// A measurement harness for the portable SQL conformance fixtures. It resolves
// the enclosing working tree by path, like database-framework's Benchmarks
// packages, so the fixtures, their testable imports, QueryAST and the client
// projection check never enter the release package graph or the Embedded
// release gate reactor.

// The WASI SDKs ship Unicode tables beside their Embedded libraries. Resolve
// the archive from the fixed Swift 6.4.0 SDK, as the enclosing package does.
let unicodeDataArchiveDirectory: String? = {
    let sdk = "swift-6.4.0-RELEASE_wasm"
    let relativePath = "\(sdk).artifactbundle/\(sdk)/wasm32-unknown-wasip1/swift.xctoolchain/usr/lib/swift/embedded/wasm32-unknown-wasip1"
    let fileManager = FileManager.default
    let userHomeDirectory = fileManager.homeDirectoryForCurrentUser
    let roots = [
        userHomeDirectory.appendingPathComponent("Library/org.swift.swiftpm/swift-sdks"),
        userHomeDirectory.appendingPathComponent(".swiftpm/swift-sdks"),
    ]
    for root in roots {
        let directory = root.appendingPathComponent(relativePath)
        let archive = directory.appendingPathComponent("libswiftUnicodeDataTables.a")
        if fileManager.fileExists(atPath: archive.path) {
            return directory.path
        }
    }
    return nil
}()

let unicodeDataSupportLinkerSettings: [LinkerSetting] = {
    guard let directory = unicodeDataArchiveDirectory else {
        return [
            .linkedLibrary(
                "swiftUnicodeDataTables",
                .when(platforms: [.wasi])
            )
        ]
    }
    return [
        .unsafeFlags(
            [
                "-Xlinker",
                "-L",
                "-Xlinker",
                directory,
                "-Xlinker",
                "-lswiftUnicodeDataTables",
            ],
            .when(platforms: [.wasi])
        )
    ]
}()

let package = Package(
    name: "cloudflare-sql-conformance",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(path: "../.."),
        .package(
            url: "https://github.com/1amageek/database-types.git",
            from: "26.1021.0"
        ),
        .package(
            url: "https://github.com/1amageek/database-framework.git",
            revision: "4fe236dc47d7d7ded0921caafb3d7e317d81b504"
        ),
        .package(
            url: "https://github.com/1amageek/database-kit.git",
            revision: "b325109676a4b9b3431e2e306ca8c0dcf1d9a7bf"
        ),
        .package(
            url: "https://github.com/1amageek/storage-kit.git",
            from: "26.1021.0"
        ),
        .package(
            url: "https://github.com/1amageek/database-client.git",
            revision: "cd81942c063e4d26ac9fd5ffb002b312dbf6580b"
        ),
    ],
    targets: [
        .executableTarget(
            name: "SQLConformanceVerification",
            dependencies: [
                .product(name: "CloudflareDatabase", package: "database-framework-cloudflare"),
                .product(name: "DatabaseClient", package: "database-client"),
                .product(name: "Database", package: "database-framework"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "QueryAST", package: "database-framework"),
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseRuntime", package: "database-framework"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "CloudflareDurableObjectStorage", package: "storage-kit"),
                .product(name: "CloudflareDurableObjectStorageWire", package: "storage-kit"),
                .product(name: "StorageKit", package: "storage-kit"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("Extern"),
            ],
            linkerSettings: unicodeDataSupportLinkerSettings + [
                .unsafeFlags([
                    "-Xlinker",
                    "--undefined=__cxa_pure_virtual",
                    "-Xlinker",
                    "-lc++abi",
                    "-Xclang-linker",
                    "-mexec-model=reactor",
                    "-Xlinker",
                    "-z",
                    "-Xlinker",
                    "stack-size=8388608",
                    "-Xlinker",
                    "--initial-memory=67108864",
                ], .when(platforms: [.wasi]))
            ]
        ),
    ]
)
