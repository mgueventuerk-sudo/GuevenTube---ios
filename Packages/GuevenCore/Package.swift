// swift-tools-version:5.10
import PackageDescription

// Reine Logik ohne UIKit/AVFoundation (Parser, Modelle, Stream-Auswahl): läuft auf Linux und macOS.
let package = Package(
    name: "GuevenCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "GuevenCore", targets: ["GuevenCore"])],
    targets: [
        .target(name: "GuevenCore"),
        .testTarget(name: "GuevenCoreTests", dependencies: ["GuevenCore"]),
    ]
)
