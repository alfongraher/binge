// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Drift",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Drift", targets: ["Drift"])],
    targets: [.executableTarget(name: "Drift")]
)
