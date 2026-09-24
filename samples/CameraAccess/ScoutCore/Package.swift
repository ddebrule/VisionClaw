// swift-tools-version: 6.0
import PackageDescription

// Pure, Foundation-only logic shared by the app and its unit tests.
// The app compiles Sources/ScoutCore directly (Xcode synchronized folder) and
// never imports this package; `swift test` builds it standalone in CI.
let package = Package(
  name: "ScoutCore",
  platforms: [.macOS(.v14), .iOS("26.0")],
  products: [.library(name: "ScoutCore", targets: ["ScoutCore"])],
  targets: [
    .target(name: "ScoutCore"),
    .testTarget(name: "ScoutCoreTests", dependencies: ["ScoutCore"]),
  ]
)
