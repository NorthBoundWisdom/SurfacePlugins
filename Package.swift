// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SurfacePlugins",
    products: [.library(name: "SurfacePluginContracts", targets: ["SurfacePluginContracts"]),
               .library(name: "SurfacePluginConformance", targets: ["SurfacePluginConformance"]),
               .library(name: "AgentPlugin", targets: ["AgentPlugin"])],
    targets: [.target(name: "SurfacePluginContracts"),
              .target(name: "AgentPlugin", dependencies: ["SurfacePluginContracts"]),
              .testTarget(name: "AgentPluginTests", dependencies: ["AgentPlugin", "SurfacePluginConformance"]),
              .target(name: "SurfacePluginConformance", dependencies: ["SurfacePluginContracts"]),
              .testTarget(name: "SurfacePluginContractsTests", dependencies: ["SurfacePluginContracts"]),
              .testTarget(name: "SurfacePluginConformanceTests", dependencies: ["SurfacePluginConformance"])],
    swiftLanguageModes: [.v6]
)
