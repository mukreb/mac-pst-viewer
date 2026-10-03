// swift-tools-version:5.9
import PackageDescription

var products: [Product] = [
    .library(name: "PSTKit", targets: ["PSTKit"]),
    .executable(name: "pstdump", targets: ["pstdump"]),
]
var targets: [Target] = [
    .target(name: "PSTKit"),
    .executableTarget(name: "pstdump", dependencies: ["PSTKit"]),
    .testTarget(
        name: "PSTKitTests",
        dependencies: ["PSTKit"],
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
products.append(.executable(name: "PSTViewer", targets: ["PSTViewer"]))
targets.append(.executableTarget(name: "PSTViewer", dependencies: ["PSTKit"]))
#endif

let package = Package(
    name: "PSTViewer",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
