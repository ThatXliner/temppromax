// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "temppromax",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "temppromax", targets: ["TempProMax"]),
    ],
    targets: [
        .target(
            name: "CHIDReader",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-fobjc-arc"]),
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "TempProMax",
            dependencies: ["CHIDReader"]
        ),
    ]
)
