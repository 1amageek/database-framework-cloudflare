// swift-tools-version: 6.4
import PackageDescription

let hostPlatforms: [Platform] = [
    .macOS,
    .iOS,
    .linux,
]

let package = Package(
    name: "database-framework-cloudflare",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "CloudflareDatabase", targets: ["CloudflareDatabase"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/1amageek/database-types.git",
            from: "26.0730.0"
        ),
        .package(
            url: "https://github.com/1amageek/database-framework.git",
            from: "26.0731.0",
            traits: []
        ),
        .package(
            url: "https://github.com/1amageek/database-kit.git",
            from: "26.0730.0"
        ),
        .package(
            url: "https://github.com/1amageek/storage-kit.git",
            from: "26.0730.0"
        ),
    ],
    targets: [
        .target(
            name: "CloudflareDatabase",
            dependencies: [
                "CloudflareDatabaseTaskScheduling",
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseServer", package: "database-framework"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "StorageKit", package: "storage-kit"),
                .product(name: "CloudflareDurableObjectStorage", package: "storage-kit"),
                .product(name: "CloudflareDurableObjectStorageWire", package: "storage-kit"),
                .product(name: "CloudflareDurableObjectStorageHostTransport", package: "storage-kit"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("Extern"),
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
                    name: "DatabaseServerFoundation",
                    package: "database-framework",
                    condition: .when(platforms: hostPlatforms)
                ),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "CloudflareDurableObjectStorage", package: "storage-kit"),
                .product(name: "CloudflareDurableObjectStorageWire", package: "storage-kit"),
                .product(
                    name: "StorageKitSystemClock",
                    package: "storage-kit",
                    condition: .when(platforms: hostPlatforms)
                ),
            ],
            path: "Tests/CloudflareDatabaseRuntimeVerification",
            swiftSettings: [
                .enableExperimentalFeature("Extern"),
            ],
            linkerSettings: [
                .linkedLibrary(
                    "swiftUnicodeDataTables",
                    .when(platforms: [.wasi])
                ),
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
            ]
        ),
    ]
)
