// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "RappRecall",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "RecallCore", targets: ["RecallCore"]),
    .executable(name: "RappRecall", targets: ["RappRecall"]),
    .executable(name: "RecallAcceptance", targets: ["RecallAcceptance"]),
  ],
  targets: [
    .target(
      name: "CSQLite",
      path: "Sources/CSQLite",
      exclude: [
        "SQLCIPHER-LICENSE.md",
        "UPSTREAM.md",
      ],
      publicHeadersPath: "include",
      cSettings: [
        .define("NDEBUG"),
        .define("SQLITE_HAS_CODEC"),
        .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
        .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
        .define("SQLCIPHER_CRYPTO_CC"),
        .define("SQLITE_ENABLE_FTS5"),
        .define("SQLITE_TEMP_STORE", to: "2"),
        .define("SQLITE_THREADSAFE", to: "1"),
        .define("SQLITE_OMIT_LOAD_EXTENSION"),
        .unsafeFlags(["-Wno-ambiguous-macro"]),
      ],
      linkerSettings: [
        .linkedFramework("Foundation"),
        .linkedFramework("Security"),
      ]
    ),
    .target(
      name: "RecallCore",
      dependencies: ["CSQLite"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("CoreImage"),
        .linkedFramework("ScreenCaptureKit"),
        .linkedFramework("Vision"),
      ]
    ),
    .executableTarget(
      name: "RappRecall",
      dependencies: ["RecallCore"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("SwiftUI"),
      ]
    ),
    .executableTarget(
      name: "RecallAcceptance",
      dependencies: ["RecallCore", "CSQLite"],
      path: "Tests/RecallAcceptance",
      linkerSettings: [
        .linkedFramework("CoreText")
      ]
    ),
  ]
)
