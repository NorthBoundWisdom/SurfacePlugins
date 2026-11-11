import Foundation

public enum ParameterKind: String, Codable, Sendable { case continuous, toggle }

/// Immutable, validated metadata; the host owns the corresponding current value.
public struct ParameterDefinition: Equatable, Codable, Sendable {
    public let id: ParameterID
    public let nameKey: String
    public let group: String
    public let unit: String
    public let minimum: Double
    public let maximum: Double
    public let defaultValue: Double
    public let kind: ParameterKind
    public let agentWritable: Bool
    public let externallyProtected: Bool
    public let step: Double?

    public init(id: ParameterID, nameKey: String, group: String = "", unit: String = "",
                minimum: Double, maximum: Double, defaultValue: Double,
                kind: ParameterKind = .continuous, agentWritable: Bool = true,
                externallyProtected: Bool = false, step: Double? = nil) throws {
        guard !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !nameKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginError(code: .invalidParameter, fields: ["field": .string("identifierOrName")])
        }
        guard minimum.isFinite, maximum.isFinite, minimum < maximum, (maximum - minimum).isFinite else {
            throw PluginError(code: .invalidParameter, fields: ["field": .string("range")])
        }
        guard defaultValue.isFinite else { throw PluginError(code: .invalidParameter, fields: ["field": .string("defaultValue")]) }
        if let step {
            guard step.isFinite, step > 0, (minimum / step).isFinite, (maximum / step).isFinite else {
                throw PluginError(code: .invalidParameter, fields: ["field": .string("step")])
            }
        }
        self.id = id; self.nameKey = nameKey; self.group = group; self.unit = unit
        self.minimum = minimum; self.maximum = maximum; self.defaultValue = defaultValue
        self.kind = kind; self.agentWritable = agentWritable; self.externallyProtected = externallyProtected; self.step = step
    }
    private enum CodingKeys: String, CodingKey { case id, nameKey, group, unit, minimum, maximum, defaultValue, kind, agentWritable, externallyProtected, step }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(ParameterID.self, forKey: .id), nameKey: c.decode(String.self, forKey: .nameKey),
                      group: c.decode(String.self, forKey: .group), unit: c.decode(String.self, forKey: .unit),
                      minimum: c.decode(Double.self, forKey: .minimum), maximum: c.decode(Double.self, forKey: .maximum),
                      defaultValue: c.decode(Double.self, forKey: .defaultValue), kind: c.decode(ParameterKind.self, forKey: .kind),
                      agentWritable: c.decode(Bool.self, forKey: .agentWritable), externallyProtected: c.decode(Bool.self, forKey: .externallyProtected),
                      step: c.decodeIfPresent(Double.self, forKey: .step))
    }
    public var midpoint: Double { minimum + (maximum - minimum) / 2 }
    /// Finite inputs clamp to the range. The zero-anchored grid also includes both endpoints.
    /// Equal distances choose the lower candidate. Nonfinite input is an error.
    public func clamp(_ value: Double) throws -> Double {
        guard value.isFinite else { throw PluginError(code: .invalidParameter, fields: ["parameter": .string(id.rawValue)]) }
        let bounded = min(max(value, minimum), maximum)
        if kind == .toggle { return bounded >= midpoint ? maximum : minimum }
        guard let step else { return bounded }
        let quotient = bounded / step
        let lower = min(max(quotient.rounded(.down) * step, minimum), maximum)
        let upper = min(max(quotient.rounded(.up) * step, minimum), maximum)
        return abs(bounded - lower) <= abs(upper - bounded) ? lower : upper
    }
    public func normalized(_ value: Double) throws -> Double { (try clamp(value) - minimum) / (maximum - minimum) }
}
