# JSONValue decoding differences (G-9)

G-9 is closed without unifying the two paths (supervision, 2026-11-16). Keep
`JSONValue.init(from:)` and `JSONValueParser` in their current roles. The observed
numeric classification, accepted syntax and Decoder differences make a byte-equivalent
replacement more expensive than the demonstrated benefit. This document records the
decision and its evidence; it does not authorize a new parser or relaxed validation.

`Sources/SurfacePluginContracts/JSONValue.swift` implements public Codable decoding
through SingleValueDecodingContainer: null, then Bool, Int, Double, String, array and
object. It supports an arbitrary caller-supplied Decoder. `decoded<T>` uses JSONEncoder
followed by Foundation JSONDecoder. The internal `JSONValueParser.swift` scanner is for
JSONEncoder-produced text; `JSONValue.encoded` tries it first and falls back to JSONDecoder
on nil. It is not the decoder for arbitrary external JSON.

## Measured compatibility differences

The G assessment used unchanged source at `8388873f43dacbcd5c0fc4e3eda5590c42b41e90`,
Apple Swift 6.4.2 / arm64 macOS. H-3 did not change either source file. Foundation tolerance
and number handling must be remeasured against each platform's own reference before a future change.

| Input / API | Internal scanner | Foundation JSONDecoder + JSONValue | Consequence |
|---|---|---|---|
| `{"a":1,"a":2}` | nil | First value: `a = .number(1)` | Rejecting or selecting the last duplicate changes existing acceptance/dispatch |
| `{"a":1,"\u0061":2}` | nil after unescaping the duplicate | Same first-value result | Escaped keys need the same collision rule |
| UTF-8 BOM + object | nil | Accepts the object in this environment | A stricter external entry would reject previously accepted input |
| `[1,]`, `{"a":1,}` | nil | Accepts them in this environment | This describes Foundation, not a JSON standard requirement |
| `0.9999999999999999999999999999999999999999` | `.double(1)` | `.number(1)` | Enum kinds differ even though both re-encode as `1` |
| `9223372036854775807.0` | `.number(Int.max)` | `.double(9.223372036854776e18)` | Enum kind and re-encoded bytes differ |
| `1e-1000` | `.number(0)` | `.number(0)` | JSONSerialization rejects it instead; it is not an equivalent intermediary |
| `9007199254740993.0` through JSONSerialization | NSNumber's doubleValue becomes `9007199254740992` | JSONDecoder's Int decode retains `9007199254740993` | Converting through Double can lose an integer bit |
| Arbitrary public Decoder | Needs raw JSON bytes and has no such API | Supported by init(from:) | Public Decoder containers have no value-kind discriminator for eliminating all trial decodes |

These counterexamples concern expanding the scanner's accepted input domain. They do not
establish a failure of the existing encoder-produced fast path. Keep Bool versus 0/1,
Int versus Double, exact/rounded accessors, structured errors and encoded bytes as distinct checks.

## Evidence and reproduction

Local G evidence is in ignored `build/g/`: `assessment.md`, `parser_probe.swift` /
`parser-probe.json`, `number_foundation_probe.swift` / `number-foundation-probe-corrected.log`,
and `parser_benchmark.swift` / `parser-benchmark.json`. These are investigation artifacts,
not build dependencies. The first NSNumber exploration used `try!` and stopped on underflow;
the corrected driver catches each error. That exploration failure was not a product crash.

To reproduce without changing product code:

1. Record `swift --version` and both source hashes. Compile the unchanged sources with a
   temporary main.swift driver using `swiftc -O Sources/SurfacePluginContracts/JSONValue.swift Sources/SurfacePluginContracts/JSONValueParser.swift PATH/TO/main.swift -o PATH/TO/probe`.
2. Make UTF-8 Data for every table input (prepend bytes EF BB BF for BOM). Compare
   `JSONValueParser.parse(data)` with `try? JSONDecoder().decode(JSONValue.self, from: data)`.
   Record enum cases, equality and JSONEncoder bytes. Preserve nil/error outcomes.
3. Separately compare JSONSerialization's NSNumber type/value/doubleValue with
   `try? JSONDecoder().decode(Int.self, from: data)`. Catch errors per input; do not first
   normalize both values through Double.
4. Future differential coverage must include typed/nested JSONValue, arbitrary Decoder,
   custom key/date/data/float strategies, duplicate/escaped keys, BOM/trailing syntax,
   integer boundaries, precision, underflow/overflow, depth, errors and re-encoded bytes.
   Authentication and routing must interpret duplicate keys consistently.

The G optimized local benchmark used ContinuousClock, warmup, seven alternating-order rounds,
value-equality checks and a consumed checksum. Median seconds for 2,000 parses of a 281-byte RPC:
0.067293958 (JSONDecoder) / 0.007758125 (scanner); for 200 parses of a 46,175-byte tool document:
0.942983250 / 0.053129958. These compare two existing paths, not a completed G-9 improvement
or end-to-end host performance. They do not justify discarding compatibility.

A future proposal needs equivalent accepted input, numeric cases, nested behavior, errors and
bytes, while retaining an explicit arbitrary-Decoder fallback. No such implementation is added here.
