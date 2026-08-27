// swift-tools-version: 6.0
//
//  RevenueDog iOS SDK
//  M1 骨架 — 依据 docs/plan/ios-sdk-design.md
//
//  平台说明：iOS 16 是产品基线；macOS 13 只是为了让纯逻辑单测能在开发机上直接
//  `swift test`（StoreKit 相关代码用 `#if canImport(StoreKit)` + `@available` 门控）。

import PackageDescription

let package = Package(
    name: "RevenueDog",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "RevenueDog", targets: ["RevenueDog"]),
    ],
    targets: [
        .target(
            name: "RevenueDog",
            path: "Sources/RevenueDog",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "RevenueDogTests",
            dependencies: ["RevenueDog"],
            path: "Tests/RevenueDogTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
