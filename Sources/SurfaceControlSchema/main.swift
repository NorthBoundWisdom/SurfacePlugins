import Foundation
import SurfaceControlContracts
import SurfacePluginContracts

let schema = JSONValue.object([
    "schema_version": .number(1),
    "contract_version": .string("1.0"),
    "tools": try .encoded(SurfaceControlTools.descriptors)
])
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(schema))
FileHandle.standardOutput.write(Data([10]))
