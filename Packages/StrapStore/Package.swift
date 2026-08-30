// swift-tools-version: 5.9
import PackageDescription

// StrapStore — the on-device SQLite store. Reimplemented for whoopmaxx; the SCHEMA is preserved
// exactly, because every installed database and every .wmbak backup already speaks it.
let package = Package(
    name: "StrapStore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "StrapStore", targets: ["StrapStore"])],
    dependencies: [
        .package(path: "../StrapProtocol"),
        // Pinned EXACT so a clean resolve cannot pull a newer upstream release on its own.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
    ],
    targets: [
        .target(name: "StrapStore",
                dependencies: ["StrapProtocol", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "StrapStoreTests",
                    dependencies: ["StrapStore", "StrapProtocol",
                                   .product(name: "GRDB", package: "GRDB.swift")],
                    resources: [.process("expected_schema.sql")]),
    ]
)
