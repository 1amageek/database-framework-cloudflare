// swift-tools-version: 6.2
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
        .executable(name: "CloudflareDatabaseRuntime", targets: ["CloudflareDatabaseRuntime"]),
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
                .product(name: "Database", package: "database-framework", condition: .when(platforms: hostPlatforms)),
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(
                    name: "CloudflareDurableObjectStorage",
                    package: "storage-kit",
                    condition: .when(platforms: hostPlatforms)
                ),
            ],
            swiftSettings: [
                .enableExperimentalFeature("Extern"),
            ]
        ),
        .executableTarget(
            name: "CloudflareDatabaseRuntime",
            dependencies: [
                "CloudflareDatabase",
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseWire", package: "database-kit"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("Extern"),
            ]
        ),
        .testTarget(
            name: "CloudflareDatabaseTests",
            dependencies: [
                "CloudflareDatabase",
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "CloudflareDurableObjectStorage", package: "storage-kit"),
            ]
        ),
    ]
)
