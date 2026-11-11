import Foundation
import SurfacePluginContracts

/// Opt-in data only. No control bindings, implicit installation, or physical transport.
public enum ExampleParameterSets {
    public static var protectedParameterIDs: Set<ParameterID> { ["arm.enabled"] }
    public static func referenceArm() throws -> [ParameterDefinition] {
        let ranges: [(String, Double, Double, Double)] = [
            ("j1", -180, 180, 0), ("j2", -90, 90, 30), ("j3", -135, 135, -60),
            ("j4", -120, 120, -20), ("j5", -180, 180, 0), ("j6", -180, 180, 0),
            ("gripper", 0, 100, 40), ("speed", 0, 100, 50)]
        var result = try ranges.map { id, min, max, value in
            try ParameterDefinition(id: .init(rawValue: "arm." + id), nameKey: "example.arm." + id,
                                    group: "example.arm", unit: id.hasPrefix("j") ? "°" : "%",
                                    minimum: min, maximum: max, defaultValue: value)
        }
        result.append(try .init(id: "arm.enabled", nameKey: "example.arm.enabled", group: "example.arm",
                                minimum: 0, maximum: 1, defaultValue: 0, kind: .toggle,
                                agentWritable: false, externallyProtected: true))
        return result
    }
}
