import XCTest
import SurfacePluginContracts
import SurfacePluginConformance

private struct SamplePlugin: ControlPlugin {
    let manifest = PluginManifest(id: "sample", version: "1", source: .mock)
    var surface: SurfaceDescriptor {
        .init(actions: [.init(id: "sample.primary", nameKey: "sample.primary", indexCount: 3)],
              indicators: [.init(id: "sample.state", nameKey: "sample.state")])
    }
    var started = false
    var state = IndicatorState(semantic: .idle)
    var lastTime: Double?
    func snapshot() -> PluginSnapshot { .init(isStarted: started, indicators: ["sample.state": state]) }
    mutating func handle(_ input: PluginInput, at time: PluginTime) throws -> PluginUpdate {
        guard time.isFinite, lastTime.map({time >= $0}) ?? true else { throw PluginError(code: .invalidTime) }
        switch input {
        case .start: started = true
        case .stop: started = false
        case .advance: break
        case let .invoke(ref, _):
            guard started else { throw PluginError(code: .stopped) }
            guard ref.pluginID == manifest.id, ref.actionID == "sample.primary" else { throw PluginError(code: .unknownAction) }
            guard let i = ref.index, (1...3).contains(i) else { throw PluginError(code: .indexOutOfRange) }
            state = .init(semantic: state.semantic == .active ? .attention : .active)
        case .parameterChanged: throw PluginError(code: .invalidParameter)
        }
        lastTime = time
        return .init(indicators: snapshot().indicators)
    }
}
/// Both layouts are intentionally confined to tests, including their presentation encodings.
private struct RingHost {
    var plugin = SamplePlugin()
    var ring = 0
    mutating func send(_ input: PluginInput, at time: Double) throws {
        let update = try plugin.handle(input, at: time)
        ring = update.indicators["sample.state"]?.semantic == .active ? 127 : 0
    }
}
private struct LayerHost {
    enum Light { case off, on, blink }
    var plugin = SamplePlugin()
    var layers: [[Light]] = [[.off], [.off]]
    mutating func send(_ input: PluginInput, at time: Double) throws {
        let update = try plugin.handle(input, at: time)
        let semantic = update.indicators["sample.state"]?.semantic
        let light: Light = semantic == .active ? .on : semantic == .attention ? .blink : .off
        for i in layers.indices { layers[i][0] = light }
    }
}
final class LayoutTests: XCTestCase {
    private var primary: PluginInput { .invoke(.init(pluginID: "sample", actionID: "sample.primary", index: 1), origin: .hardware) }
    func testConformance() throws {
        try PluginConformance.check(make: { SamplePlugin() }, sequence: [.init(.start, at: 0), .init(primary, at: 1), .init(primary, at: 2), .init(.stop, at: 3)],
            unknownAction: .invoke(.init(pluginID: "sample", actionID: "sample.unknown"), origin: .interface),
            outOfRange: .invoke(.init(pluginID: "sample", actionID: "sample.primary", index: 4), origin: .interface), writeAfterStop: primary)
    }
    func testLayoutsShareStateWithoutSharingPresentation() throws {
        var ring = RingHost(), layers = LayerHost()
        for (i, input) in [PluginInput.start, primary, primary].enumerated() {
            try ring.send(input, at: Double(i)); try layers.send(input, at: Double(i))
            XCTAssertEqual(ring.plugin.snapshot(), layers.plugin.snapshot())
            if i == 1 { XCTAssertEqual(ring.ring, 127); XCTAssertEqual(layers.layers[0][0], .on) }
        }
        XCTAssertEqual(layers.layers[1][0], .blink)
    }
    func testBadDeclarationsFail() throws {
        struct Invalid: ControlPlugin {
            let manifest = PluginManifest(id: "sample", version: "1", source: .mock)
            let surface = SurfaceDescriptor(actions: [.init(id: "foreign.action", nameKey: "x")])
            func snapshot() -> PluginSnapshot { .init(isStarted: false) }
            mutating func handle(_ input: PluginInput, at time: PluginTime) throws -> PluginUpdate { .init() }
        }
        XCTAssertThrowsError(try PluginConformance.declarations(Invalid()))
    }
}
