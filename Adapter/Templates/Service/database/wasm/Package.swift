// swift-tools-version: 6.4

import PackageDescription

let databaseRuntimeMaximumMemoryBytes = {{service.database.maximumMemoryBytes}}

let package = Package(
    name: "{{service.application.kebabName}}-cloudflare-database",
    products: [
        .executable(
            name: "DatabaseServiceLauncher",
            targets: ["DatabaseServiceLauncher"]
        ),
    ],
    dependencies: [
        .package(path: "{{project.root}}"),
        .package(
            {{service.adapter.swiftPackageRequirement}}{{service.adapter.swiftPackageTraits}}
        ),
    ],
    targets: [
        .executableTarget(
            name: "DatabaseServiceLauncher",
            dependencies: [
                .product(
                    name: "{{service.application.product}}",
                    package: "{{service.application.packageIdentity}}"
                ),
                .product(
                    name: "CloudflareDatabase",
                    package: "database-framework-cloudflare"
                ),
            ],
            linkerSettings: [
                .linkedLibrary("swiftUnicodeDataTables"),
                .unsafeFlags([
                    "-Xlinker", "--undefined=__cxa_pure_virtual",
                    "-Xlinker", "-lc++abi",
                    "-Xclang-linker", "-mexec-model=reactor",
                    "-Xlinker", "-z",
                    "-Xlinker", "stack-size=8388608",
                    "-Xlinker", "--initial-memory=\(databaseRuntimeMaximumMemoryBytes)",
                    "-Xlinker", "--max-memory=\(databaseRuntimeMaximumMemoryBytes)",
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
