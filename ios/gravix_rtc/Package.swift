// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "gravix_rtc",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "gravix-rtc", targets: ["gravix_rtc"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        // The flutter_webrtc plugin package. Its `WebRTC` product re-exports the
        // same WebRTC binary target, so the app links exactly one copy.
        //
        // The documented form for a dependency on another Flutter plugin: the
        // Flutter tool rewrites the path to the resolved version's symlink
        // ("<name>-<version>"), so every flutter_webrtc the pubspec allows
        // (>=1.6.0 <1.7.0) resolves. 0.4.10: was pinned to the 1.6.0 symlink,
        // which broke the SwiftPM build with 1.6.2+hotfix.3 (what a fresh
        // `pub get` resolves). To do that the tool copies this package's root
        // into the app's build/ios/SourcePackages; the in-repo example would
        // copy its own build/ into itself on every build, so the example
        // builds with CocoaPods (example/pubspec.yaml).
        .package(name: "flutter_webrtc", path: "../flutter_webrtc")
    ],
    targets: [
        .target(
            name: "gravix_rtc",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "flutter-webrtc", package: "flutter_webrtc"),
                .product(name: "WebRTC", package: "flutter_webrtc")
            ],
            resources: [
                // If your plugin requires a privacy manifest, for example if it uses any required
                // reason APIs, update the PrivacyInfo.xcprivacy file to describe your plugin's
                // privacy impact, and then uncomment these lines. For more information, see
                // https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
                .process("PrivacyInfo.xcprivacy"),
            ]
        )
    ]
)
