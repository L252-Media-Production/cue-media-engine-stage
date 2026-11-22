import AudioCore
import Foundation

/// Where the fixtures of the pinned spec version live, and how to read them.
enum AudioSpec {
    /// The spec version this code implements. Every fixture must say the same.
    static var pinnedVersion: Int { AudioCore.implementedSpecVersion }

    /// Constants of the spec itself (docs/AUDIO-SPEC.md), not of any one fixture: 48 kHz, 16-bit, stereo, and the 10 ms control step.
    static let sampleRate = 48_000
    static let channels = 2
    static let controlStepS = 0.01

    static let fixtureFiles = [
        "fades", "xfade", "trim", "end_actions", "play_modes", "triggers", "ducking", "levelmatch", "resume_flow",
    ]

    static var fixturesRoot: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)
    }

    static var directory: URL {
        fixturesRoot.appendingPathComponent("spec-\(pinnedVersion)", isDirectory: true)
    }

    /// A file of the pinned spec folder, by its path inside it (`SPEC_VERSION`, `renders/renders.json`).
    static func url(_ path: String) -> URL {
        directory.appendingPathComponent(path)
    }

    /// A fixture JSON by name (`fades`) or path (`renders/renders.json`).
    static func fixtureURL(_ name: String) -> URL {
        url(name.hasSuffix(".json") ? name : name + ".json")
    }
}

enum FixtureError: Error, CustomStringConvertible {
    case missing(String)
    case versionMismatch(file: String, found: Int, pinned: Int)

    var description: String {
        switch self {
        case .missing(let path):
            return "fixture not found: \(path). Run scripts/sync-audio-spec.sh, or update AudioCore.implementedSpecVersion."
        case .versionMismatch(let file, let found, let pinned):
            return "\(file) has spec_version \(found) but the pinned version is \(pinned). See docs/audio-conformance.md."
        }
    }
}

/// The envelope shared by every fixture file, for the typed ROWS of the cases. `_info*` keys and `about` are ignored.
/// It carries no tolerance on purpose: a tolerance belongs to a case (`FixtureCase.tolerance`, which honours a case-level override).
struct Fixture<Cases: Decodable>: Decodable {
    let specVersion: Int
    let name: String
    let cases: Cases

    enum CodingKeys: String, CodingKey {
        case specVersion = "spec_version"
        case name, cases
    }
}

enum FixtureLoader {
    /// Reads `<file>.json` of the pinned spec folder. Throws when the file is missing or its `spec_version` is not the pinned one.
    static func load<Cases: Decodable>(_ file: String, as type: Cases.Type = Cases.self) throws -> Fixture<Cases> {
        let url = AudioSpec.fixtureURL(file)
        guard let data = try? Data(contentsOf: url) else { throw FixtureError.missing(url.path) }
        return try decode(data, file: file)
    }

    /// Decodes fixture JSON and checks its `spec_version` against the pinned one.
    static func decode<Cases: Decodable>(_ data: Data, file: String, as type: Cases.Type = Cases.self) throws -> Fixture<Cases> {
        let fixture = try JSONDecoder().decode(Fixture<Cases>.self, from: data)
        guard fixture.specVersion == AudioSpec.pinnedVersion else {
            throw FixtureError.versionMismatch(file: file, found: fixture.specVersion, pinned: AudioSpec.pinnedVersion)
        }
        return fixture
    }

    /// The `spec_version` of a JSON file without decoding anything else (nil when the file or the key is missing).
    static func specVersion(ofFile file: String) -> Int? {
        guard let data = try? Data(contentsOf: AudioSpec.fixtureURL(file)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object["spec_version"] as? Int
    }
}

/// A dictionary whose keys starting with `_info` are dropped before the values are decoded.
struct InfoFilteredDictionary<Value: Decodable>: Decodable {
    let values: [String: Value]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var out = [String: Value]()
        for key in container.allKeys where !key.stringValue.hasPrefix("_info") {
            out[key.stringValue] = try container.decode(Value.self, forKey: key)
        }
        values = out
    }
}

struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// `{ "rows": [...] }`: the shape of most cases.
struct Rows<Row: Decodable>: Decodable {
    let rows: [Row]
}

/// A JSON scalar of a fixture input that can be a number or text ("abc" in xfade.json).
enum FixtureScalar: Decodable, Equatable {
    case number(Double)
    case text(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else {
            self = .text(try c.decode(String.self))
        }
    }
}
