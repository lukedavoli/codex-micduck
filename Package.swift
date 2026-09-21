// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexMicDuck",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "CodexMicDuck", targets: ["CodexMicDuck"]),
    ],
    targets: [
        .executableTarget(
            name: "CodexMicDuck",
            path: "Sources/CodexSpotifyDuck",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ScriptingBridge"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
