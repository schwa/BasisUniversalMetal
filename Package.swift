// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BasisUniversalMetal",
    platforms: [.macOS(.v14), .iOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "BasisUniversalMetal", targets: ["BasisUniversalMetal"]),
    ],
    targets: [
        .target(
            name: "CBasisUniversal",
            exclude: ["vendor/LICENSE", "vendor/NOTICE", "vendor/VERSION", "vendor/zstd/LICENSE"],
            sources: [
                "vendor/transcoder/basisu_transcoder.cpp",
                "vendor/encoder/basisu_wasm_transcoder_api.cpp",
                "vendor/zstd/zstddeclib.c",
            ],
            cSettings: [
                .define("BASISD_SUPPORT_KTX2", to: "1"),
                .define("BASISD_SUPPORT_KTX2_ZSTD", to: "1"),
            ],
            cxxSettings: [
                .define("BASISD_SUPPORT_KTX2", to: "1"),
                .define("BASISD_SUPPORT_KTX2_ZSTD", to: "1"),
                // Formats Metal can't sample.
                .define("BASISD_SUPPORT_PVRTC1", to: "0"),
                .define("BASISD_SUPPORT_PVRTC2", to: "0"),
                .define("BASISD_SUPPORT_ATC", to: "0"),
                .define("BASISD_SUPPORT_FXT1", to: "0"),
            ]
        ),
        .target(name: "BasisUniversalMetal", dependencies: ["CBasisUniversal"]),
        .testTarget(
            name: "BasisUniversalMetalTests",
            dependencies: ["BasisUniversalMetal"],
            resources: [.copy("Resources")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
