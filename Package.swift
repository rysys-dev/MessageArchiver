// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MessageArchiver",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "MessageArchiverCore", targets: ["MessageArchiverCore"]),
        .executable(name: "MessageArchiverApp", targets: ["MessageArchiverApp"]),
    ],
    targets: [
        .target(name: "MessageArchiverCore"),
        .executableTarget(name: "MessageArchiverApp", dependencies: ["MessageArchiverCore"]),
    ],
    swiftLanguageModes: [.v6]
)
