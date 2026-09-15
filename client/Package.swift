// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "RevivalTradingClient",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "RevivalTradingClient", targets: ["RevivalTradingClient"])],
    targets: [
        .target(name: "RevivalTradingClient"),
        .testTarget(name: "RevivalTradingClientTests", dependencies: ["RevivalTradingClient"])
    ]
)
