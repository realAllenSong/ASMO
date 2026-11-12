// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ASMOCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    targets: [
        .target(name: "ASMOCore", path: "ASMO/Domain"),
        // The `asmo` command for coding agents; script/install.sh puts it in ~/.local/bin.
        .executableTarget(name: "asmo", path: "CLI", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ASMOCoreTests", dependencies: ["ASMOCore"], path: "Tests")
    ]
)
