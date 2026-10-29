// swift-tools-version: 6.2
import PackageDescription

// Pixel Agency Library: `ImageLibrary`, the GRDB job ledger and asset library that share one SQLite file, and the
// content-addressed blob store beside it. It was ML[X] Image Server's (ImageServerKit, c96e6dc) and moved here when the
// Image Server retires at Gaea's G1 exit (G-15, G-20; AB-D-0182 item 1; AB-T-0358). Pixel Agency Desktop keeps its
// library in it; Desktop's own tables (tickets, variants and their ledger) live in the same database.
//
// Its only engine-side dependency is the wire types (`ImageServerAPI`, MLXToolKit's vocabulary): no MLX is built.
let package = Package(
    name: "PixelAgencyLibrary",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ImageLibrary", targets: ["ImageLibrary"]),
    ],
    dependencies: [
        // ImageServerAPI: job snapshots, model and licence vocabulary, asset records. MLXToolKit only, no MLX.
        .package(url: "https://github.com/xocialize/mlx-image-runtime.git", from: "0.7.0"),
        // MLXToolKit: Capability, which descriptions are keyed by.
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.66.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "ImageLibrary", dependencies: [
            .product(name: "ImageServerAPI", package: "mlx-image-runtime"),
            .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(name: "ImageLibraryTests", dependencies: [
            "ImageLibrary",
            .product(name: "ImageServerAPI", package: "mlx-image-runtime"),
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
    ]
)
