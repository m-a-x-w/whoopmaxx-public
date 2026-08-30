// swift-tools-version: 5.9
import PackageDescription

// StrapAnalytics — scores, baselines and sleep staging. Reimplemented for whoopmaxx.
let package = Package(
    name: "StrapAnalytics",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "StrapAnalytics", targets: ["StrapAnalytics"])],
    dependencies: [
        .package(path: "../StrapProtocol"),
        .package(path: "../StrapStore"),
    ],
    targets: [
        .target(name: "StrapAnalytics", dependencies: ["StrapProtocol", "StrapStore"]),
        .testTarget(name: "StrapAnalyticsTests",
                    dependencies: ["StrapAnalytics", "StrapProtocol", "StrapStore"]),
    ]
)
