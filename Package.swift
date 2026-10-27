// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenMeter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TokenMeter", targets: ["TokenMeter"])],
    targets: [.executableTarget(name: "TokenMeter")]
)
