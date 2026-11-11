// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SurfacePlugins",
    products: [.library(name: "SurfacePluginContracts", targets: ["SurfacePluginContracts"]),
               .library(name: "SurfacePluginConformance", targets: ["SurfacePluginConformance"]),
               .library(name: "AgentPlugin", targets: ["AgentPlugin"]),
               .library(name: "SimulationContracts", targets: ["SimulationContracts"]),
               .library(name: "RobotPlugin", targets: ["RobotPlugin"]),
               .library(name: "ChassisPlugin", targets: ["ChassisPlugin"]),
               .library(name: "ParameterOutputPlugin", targets: ["ParameterOutputPlugin"]),
               .library(name: "ExampleParameterSets", targets: ["ExampleParameterSets"])],
    targets: [.target(name: "SurfacePluginContracts"),
              .target(name: "SimulationContracts", dependencies: ["SurfacePluginContracts"]),
              .target(name: "ParameterOutputPlugin", dependencies: ["SurfacePluginContracts"]),
              .target(name: "ExampleParameterSets", dependencies: ["SurfacePluginContracts"]),
              .testTarget(name: "ParameterOutputPluginTests", dependencies: ["ParameterOutputPlugin", "ExampleParameterSets", "SurfacePluginConformance"]),
              .target(name: "ChassisPlugin", dependencies: ["SurfacePluginContracts", "SimulationContracts"]),
              .testTarget(name: "ChassisPluginTests", dependencies: ["ChassisPlugin", "RobotPlugin", "SurfacePluginConformance"]),
              .target(name: "RobotPlugin", dependencies: ["SurfacePluginContracts", "SimulationContracts"]),
              .testTarget(name: "RobotPluginTests", dependencies: ["RobotPlugin", "SurfacePluginConformance"]),
              .target(name: "AgentPlugin", dependencies: ["SurfacePluginContracts"]),
              .testTarget(name: "AgentPluginTests", dependencies: ["AgentPlugin", "SurfacePluginConformance"]),
              .target(name: "SurfacePluginConformance", dependencies: ["SurfacePluginContracts"]),
              .testTarget(name: "SurfacePluginContractsTests", dependencies: ["SurfacePluginContracts"]),
              .testTarget(name: "SurfacePluginConformanceTests", dependencies: ["SurfacePluginConformance"])],
    swiftLanguageModes: [.v6]
)
