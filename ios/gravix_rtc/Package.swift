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
        // The path is the name the Flutter tool gives flutter_webrtc's symlink
        // (`<name>-<version>`, next to this package's own symlink), spelled out
        // on purpose. Written as the bare package name (dot-dot-slash flutter_webrtc,
        // not quoted here because the tool greps this file) the tool would instead
        // rsync this ENTIRE package root (example/ and its build/ included)
        // into the app's build/ios/SourcePackages to rewrite the path, and for
        // the in-repo example app, whose build/ lives inside that root, every
        // build nested one more copy (tens of GB after a few builds).
        // pubspec pins flutter_webrtc to exactly 1.6.0; keep the two in step.
        .package(name: "flutter_webrtc", path: "../flutter_webrtc-1.6.0")
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
