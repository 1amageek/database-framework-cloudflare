// swift-tools-version: 6.4
import PackageDescription
import Foundation

// The Embedded WASI SDK ships Unicode tables outside the default linker search
// path. Resolve the archive from the fixed Swift 6.4 SDK so every reactor
// build links the same standard-library support without adding it to the
// runtime dependency graph.
let unicodeDataArchiveDirectory: String? = {
    let snapshot = "swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-23-a_wasm"
    let relativePath = "\(snapshot).artifactbundle/\(snapshot)/wasm32-unknown-wasip1/swift.xctoolchain/usr/lib/swift/embedded/wasm32-unknown-wasip1"
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser
    let roots = [
        home.appendingPathComponent("Library/org.swift.swiftpm/swift-sdks"),
        home.appendingPathComponent(".swiftpm/swift-sdks"),
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

let hostPlatforms: [Platform] = [
    .macOS,
    .iOS,
    .linux,
]

let databaseRuntimeFeatureNames: Set<String> = [
    "ScalarIndexes",
    "VectorIndexes",
    "FullTextIndexes",
    "SpatialIndexes",
    "RankIndexes",
    "BitmapIndexes",
    "VersionIndexes",
    "PermutedIndexes",
    "GraphIndexes",
    "AggregationIndexes",
    "LeaderboardIndexes",
    "Relationships",
]

var databaseRuntimeTraits = Set(
    databaseRuntimeFeatureNames.map {
        Trait.trait(name: $0)
    }
)
databaseRuntimeTraits.insert(
    .trait(
        name: "AllRuntimeFeatures",
        enabledTraits: databaseRuntimeFeatureNames
    )
)
databaseRuntimeTraits.insert(
    .default(enabledTraits: ["AllRuntimeFeatures"])
)

let databaseFrameworkDependencyTraits = Set(
    databaseRuntimeFeatureNames.map {
        Package.Dependency.Trait.trait(
            name: $0,
            condition: .when(traits: [$0])
        )
    }
)

let package = Package(
    name: "database-framework-cloudflare",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "CloudflareDatabase", targets: ["CloudflareDatabase"]),
    ],
    traits: databaseRuntimeTraits,
    dependencies: [
        .package(
            url: "https://github.com/1amageek/database-types.git",
            from: "26.0730.0"
        ),
        .package(
            url: "https://github.com/1amageek/database-framework.git",
            from: "26.0809.1",
            traits: databaseFrameworkDependencyTraits
        ),
        .package(
            url: "https://github.com/1amageek/database-kit.git",
            from: "26.0809.4"
        ),
        .package(
            url: "https://github.com/1amageek/storage-kit.git",
            from: "26.0807.0"
        ),
    ],
    targets: [
        .target(
            name: "CloudflareDatabase",
            dependencies: [
                "CloudflareDatabaseTaskScheduling",
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseServer", package: "database-framework"),
                .product(
                    name: "VectorIndex",
                    package: "database-framework",
                    condition: .when(traits: ["VectorIndexes"])
                ),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "StorageKit", package: "storage-kit"),
                .product(name: "CloudflareDurableObjectStorage", package: "storage-kit"),
                .product(name: "CloudflareDurableObjectStorageWire", package: "storage-kit"),
                .product(name: "CloudflareDurableObjectStorageHostTransport", package: "storage-kit"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("Extern"),
                .define(
                    "CLOUDFLARE_DATABASE_VECTOR_INDEXES",
                    .when(traits: ["VectorIndexes"])
                ),
            ]
        ),
        .target(
            name: "CloudflareDatabaseTaskScheduling"
        ),
        .executableTarget(
            name: "CloudflareDatabaseRuntimeVerification",
            dependencies: [
                "CloudflareDatabase",
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseRuntime", package: "database-framework"),
                .product(name: "DatabaseServer", package: "database-framework"),
                .product(
                    name: "VectorIndex",
                    package: "database-framework",
                    condition: .when(traits: ["VectorIndexes"])
                ),
                .product(
                    name: "DatabaseServerFoundation",
                    package: "database-framework",
                    condition: .when(platforms: hostPlatforms)
                ),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "CloudflareDurableObjectStorage", package: "storage-kit"),
                .product(name: "CloudflareDurableObjectStorageWire", package: "storage-kit"),
                .product(name: "StorageKit", package: "storage-kit"),
                .product(
                    name: "StorageKitSystemClock",
                    package: "storage-kit",
                    condition: .when(platforms: hostPlatforms)
                ),
            ],
            path: "Tests/CloudflareDatabaseRuntimeVerification",
            swiftSettings: [
                .enableExperimentalFeature("Extern"),
                .define(
                    "CLOUDFLARE_RUNTIME_VECTOR_INDEXES",
                    .when(traits: ["VectorIndexes"])
                ),
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
                ], .when(platforms: [.wasi])),
            ]
        ),
        .testTarget(
            name: "CloudflareDatabaseTests",
            dependencies: [
                "CloudflareDatabase",
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseRuntime", package: "database-framework"),
                .product(name: "DatabaseServer", package: "database-framework"),
                .product(
                    name: "VectorIndex",
                    package: "database-framework",
                    condition: .when(traits: ["VectorIndexes"])
                ),
                .product(
                    name: "DatabaseServerFoundation",
                    package: "database-framework",
                    condition: .when(platforms: hostPlatforms)
                ),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "CloudflareDurableObjectStorage", package: "storage-kit"),
                .product(name: "CloudflareDurableObjectStorageWire", package: "storage-kit"),
                .product(
                    name: "CloudflareDurableObjectStorageTesting",
                    package: "storage-kit"
                ),
                .product(name: "StorageKit", package: "storage-kit"),
                .product(
                    name: "StorageKitSystemClock",
                    package: "storage-kit",
                    condition: .when(platforms: hostPlatforms)
                ),
            ],
            swiftSettings: [
                .define(
                    "CLOUDFLARE_TEST_VECTOR_INDEXES",
                    .when(traits: ["VectorIndexes"])
                ),
            ]
        ),
    ]
)
