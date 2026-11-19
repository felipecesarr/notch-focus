// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NotchFocus",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NotchFocus", targets: ["NotchFocus"])],
    targets: [
        .executableTarget(name: "NotchFocus", resources: [.process("Resources")]),
        .testTarget(name: "NotchFocusTests", dependencies: ["NotchFocus"])
    ]
)
