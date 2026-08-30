// swift-tools-version: 5.9
import PackageDescription

// StrapProtocol — WHOOP wire-format decode. Reimplemented for whoopmaxx from
// OpenStrap/protocol (MIT, Copyright 2026 OpenStrap); see NOTICE at the repo root.
// Zero dependencies on purpose: this layer is pure bytes-in / values-out and must stay
// testable without a store, a radio, or a platform.
let package = Package(
    name: "StrapProtocol",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "StrapProtocol", targets: ["StrapProtocol"])],
    targets: [
        .target(name: "StrapProtocol"),
        .testTarget(name: "StrapProtocolTests", dependencies: ["StrapProtocol"],
                    resources: [.process("Resources")]),
    ]
)
