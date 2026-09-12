// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TeslaBLEKeyKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v9),
    ],
    products: [
        .library(
            name: "TeslaBLEKeyKit",
            targets: ["TeslaBLEKeyKit"]
        ),
        .library(
            name: "TeslaBLEKeyKitCore",
            targets: ["TeslaBLEKeyKitCore"]
        ),
        .library(
            name: "TeslaBLEKeyKitCrypto",
            targets: ["TeslaBLEKeyKitCrypto"]
        ),
        .library(
            name: "TeslaBLEKeyKitBLE",
            targets: ["TeslaBLEKeyKitBLE"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.28.2"),
    ],
    targets: [
        .target(
            name: "TeslaBLEKeyKitCore",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            exclude: [
                "Protos",
            ]
        ),
        .target(
            name: "TeslaBLEKeyKitCrypto",
            dependencies: ["TeslaBLEKeyKitCore"]
        ),
        .target(
            name: "TeslaBLEKeyKitBLE",
            dependencies: ["TeslaBLEKeyKitCore"],
            linkerSettings: [
                .linkedFramework("CoreBluetooth", .when(platforms: [.iOS, .macOS, .watchOS])),
            ]
        ),
        .target(
            name: "TeslaBLEKeyKit",
            dependencies: [
                "TeslaBLEKeyKitCore",
                "TeslaBLEKeyKitCrypto",
                "TeslaBLEKeyKitBLE",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(name: "InspectorTests", dependencies: ["TeslaBLEKeyKit"], path: "Tests/InspectorTests"),
    ]
)
