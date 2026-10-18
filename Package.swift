// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WatchLock", platforms: [.macOS(.v14)], products: [.library(name: "WatchLockCore", targets: ["WatchLockCore"])], targets: [.target(name: "WatchLockCore", path: "WatchLock/Core"), .testTarget(name: "WatchLockCoreTests", dependencies: ["WatchLockCore"])])
