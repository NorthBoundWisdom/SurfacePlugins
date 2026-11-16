import XCTest
import SurfacePluginContracts
import SurfaceControlContracts

final class ControlV15ActivationTests: XCTestCase {
    func testInputRetentionCapabilityRequiresIndependentSequence() throws {
        let p = ControlProfile(id: "retained", version: "1.5", controls: [
            .init(id: "button", inputKind: .button, encoding: .boolean)
        ], capabilities: ["simulation", "input.button", "input.independent_sequence", "events.input_retention"])
        // A registered declaration is valid; a session separately requires explicit retention capacity.
        XCTAssertNoThrow(try p.validate())
        XCTAssertEqual(ControlDiscovery(expected: .init(instanceID: "I", epoch: "E", mappingRevision: p.mappingRevision, profileID: p.id, profileVersion: p.version), profile: p, latestSequence: "0", latestInputSequence: "0").contract_version, "1.5")
    }
}
