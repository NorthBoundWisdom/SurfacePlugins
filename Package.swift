// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SurfacePlugins",
    products: [.library(name: "SurfacePluginContracts", targets: ["SurfacePluginContracts"])],
    targets: [.target(name: "SurfacePluginContracts"),
              .testTarget(name: "SurfacePluginContractsTests", dependencies: ["SurfacePluginContracts"])],
    swiftLanguageModes: [.v6]
)
