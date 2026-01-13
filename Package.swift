// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GlowClip",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "GlowClip", targets: ["GlowClip"])
    ],
    targets: [
        // Main executable target
        // Entry point: Sources/AppDelegate.swift with @main annotation
        .executableTarget(
            name: "GlowClip"),
    ]
)
