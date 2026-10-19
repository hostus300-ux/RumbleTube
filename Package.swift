// swift-tools-version:5.9
// Builds only the Foundation-level core so its logic can be unit-tested anywhere (`swift test`),
// including Linux. The iOS app itself is generated from project.yml with XcodeGen.
import PackageDescription

let package = Package(
    name: "RumbleCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(name: "RumbleCore", dependencies: ["SwiftSoup"], path: "RumbleTube/Core"),
        .testTarget(name: "RumbleCoreTests", dependencies: ["RumbleCore"], path: "Tests/RumbleCoreTests",
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageVersions: [.v5]
)
