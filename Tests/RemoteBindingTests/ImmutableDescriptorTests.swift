import XCTest
import SurfacePluginContracts
import RemoteToolContracts
import RobotPlugin
import RobotRemoteBinding
import ChassisPlugin
import ChassisRemoteBinding
import ParameterOutputPlugin
import OutputRemoteBinding

final class ImmutableDescriptorTests: XCTestCase {
    func testDescriptorsDoNotCaptureInstanceOrLifecycleState() throws {
        // Empty gates are invalid: use a valid axis so this fixture reaches every descriptor,
        // lifecycle and cross-instance routing assertion below.
        let limits = [MotionLimit(id: "axis", minimum: 0, maximum: 1, maximumChange: 1, maximumVelocity: 1)]
        let first: [any RemoteBinding] = [
            RobotRemoteBinding(instanceID: "robot.a", plugin: try RobotPlugin(instanceID: "robot.a")),
            ChassisRemoteBinding(instanceID: "chassis.a", plugin: try ChassisPlugin(instanceID: "chassis.a")),
            OutputRemoteBinding(instanceID: "output.a", plugin: try ParameterOutputPlugin(limits: limits))
        ]
        let second: [any RemoteBinding] = [
            RobotRemoteBinding(instanceID: "robot.b", plugin: try RobotPlugin(instanceID: "robot.b")),
            ChassisRemoteBinding(instanceID: "chassis.b", plugin: try ChassisPlugin(instanceID: "chassis.b")),
            OutputRemoteBinding(instanceID: "output.b", plugin: try ParameterOutputPlugin(limits: limits))
        ]
        for (var binding, other) in zip(first, second) {
            let tools = binding.tools
            XCTAssertFalse(tools.isEmpty)
            XCTAssertEqual(tools, other.tools)
            _ = try binding.handle(.start, at: 0)
            XCTAssertEqual(binding.tools, tools)
            _ = try binding.handle(.stop, at: 1)
            XCTAssertEqual(binding.tools, tools)
            // Instance routing remains a per-call check even when descriptors share storage.
            XCTAssertThrowsError(try binding.call(tools[0].name, arguments: .object(["instance_id": .string(other.instanceID)]), context: .init(time: 1)))
        }
    }
}
