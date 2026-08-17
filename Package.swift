// swift-tools-version: 5.9
import PackageDescription

// Deliberately dependency-free. Everything this app does is Foundation, AppKit,
// SwiftUI and IOKit — all of which ship with macOS. A tool that edits your shell
// config and reads your home directory should be auditable in an afternoon, and
// every dependency is one more thing a reviewer has to take on trust.
//
// The split is: almost everything lives in the LanesKit library, and the Lanes
// executable is one line that starts it. That is not architectural purity — it is
// so `swift test` can reach the code. An executable target cannot be imported by a
// test target, so anything worth testing has to live in a library.
let package = Package(
    name: "Lanes",
    platforms: [
        // MenuBarExtra, SMAppService and .foregroundStyle all arrive in macOS 13.
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Lanes", targets: ["Lanes"]),
        .library(name: "LanesKit", targets: ["LanesKit"]),
    ],
    targets: [
        .target(name: "LanesKit"),
        .executableTarget(name: "Lanes", dependencies: ["LanesKit"]),
        .testTarget(name: "LanesKitTests", dependencies: ["LanesKit"]),
    ]
)
