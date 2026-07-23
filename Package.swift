// swift-tools-version: 6.4
import PackageDescription

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
        .package(path: "../database-framework", traits: []),
        .package(path: "../database-kit"),
        .package(path: "../storage-kit"),
    ],
    targets: [
        .target(
            name: "CloudflareDatabase",
            dependencies: [
                "CloudflareDatabaseTaskScheduling",
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseServer", package: "database-framework"),
                .product(name: "DatabaseValue", package: "database-kit"),
                .product(name: "StorageKit", package: "storage-kit"),
                .product(name: "CloudflareDurableObjectStorage", package: "storage-kit"),
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
                .product(name: "Core", package: "database-kit"),
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseRuntime", package: "database-framework"),
                .product(name: "DatabaseServer", package: "database-framework"),
                .product(name: "DatabaseValue", package: "database-kit"),
                .product(name: "CloudflareDurableObjectStorage", package: "storage-kit"),
            ],
            path: "Tests/CloudflareDatabaseRuntimeVerification",
            swiftSettings: [
                .enableExperimentalFeature("Extern"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xclang-linker",
                    "-mexec-model=reactor",
                    "-Xlinker",
                    "-z",
                    "-Xlinker",
                    "stack-size=8388608",
                ], .when(platforms: [.wasi])),
            ]
        ),
        .testTarget(
            name: "CloudflareDatabaseTests",
            dependencies: [
                "CloudflareDatabase",
                .product(name: "Core", package: "database-kit"),
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseRuntime", package: "database-framework"),
                .product(name: "DatabaseServer", package: "database-framework"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseValue", package: "database-kit"),
                .product(name: "CloudflareDurableObjectStorage", package: "storage-kit"),
                .product(
                    name: "CloudflareDurableObjectStorageTesting",
                    package: "storage-kit"
                ),
                .product(name: "StorageKit", package: "storage-kit"),
            ]
        ),
    ]
)
