// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "RevivalGoogleLogin",
    platforms: [.iOS(.v15)],
    products: [.library(name: "RevivalGoogleLogin", targets: ["RevivalGoogleLogin"])],
    dependencies: [
        .package(name: "RevivalTradingClient", path: ".."),
        .package(url: "https://github.com/google/GoogleSignIn-iOS.git", exact: "9.0.0")
    ],
    targets: [
        .target(name: "RevivalGoogleLogin", dependencies: [
            .product(name: "RevivalTradingClient", package: "RevivalTradingClient"),
            .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS")
        ], path: ".", sources: ["GoogleLoginCoordinator.swift"])
    ]
)
