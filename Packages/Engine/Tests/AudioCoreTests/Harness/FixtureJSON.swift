import Foundation

// The raw side of the fixtures. The typed Codable models (FixtureModels.swift) read the ROWS of a case; everything a case was generated
// from (its `scenario`) and its tolerances are read from here, as a generic JSON value with accessors that fail loudly.
//
// Nothing in here defaults: a missing key or a value of the wrong type throws a `FixtureReadError` that names the fixture file, the case and the key.

// MARK: JSON value (keeps the order of object keys: playlists are named and ordered by the file)

enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    /// Pairs in file order.
    case object([(key: String, value: JSONValue)])

    static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    var kind: String {
        switch self {
        case .null: return "null"
        case .bool: return "a boolean"
        case .number: return "a number"
        case .string: return "a string"
        case .array: return "an array"
        case .object: return "an object"
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    var keys: [String] {
        guard case .object(let pairs) = self else { return [] }
        return pairs.map(\.key)
    }

    /// Back to JSON text, so a part of the tree can go through a `Decodable`.
    func serialized() -> Data {
        var out = ""
        write(to: &out)
        return Data(out.utf8)
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s):
            let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
            let text = String(decoding: data, as: UTF8.self)
            out += String(text.dropFirst().dropLast())
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(to: &out)
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out += "," }
                JSONValue.string(pair.key).write(to: &out)
                out += ":"
                pair.value.write(to: &out)
            }
            out += "}"
        }
    }
}

/// A small recursive-descent JSON parser. Foundation's would do, but it forgets the order of object keys.
struct JSONParser {
    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    private let bytes: [UInt8]
    private var i = 0

    static func parse(_ data: Data) throws -> JSONValue {
        var p = JSONParser(bytes: Array(data))
        let v = try p.value()
        p.skipSpace()
        guard p.i == p.bytes.count else { throw p.fail("unexpected text after the JSON value") }
        return v
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private func fail(_ what: String) -> ParseError { ParseError(description: "invalid JSON at byte \(i): \(what)") }

    private mutating func skipSpace() {
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
    }

    private mutating func value() throws -> JSONValue {
        skipSpace()
        guard i < bytes.count else { throw fail("unexpected end") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return try number()
        }
    }

    private mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw fail("expected \(word)") }
        i += w.count
    }

    private mutating func number() throws -> JSONValue {
        let start = i
        while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
        guard let n = Double(String(decoding: bytes[start..<i], as: UTF8.self)) else { throw fail("bad number") }
        return .number(n)
    }

    private mutating func string() throws -> String {
        i += 1 // opening quote
        var raw = [UInt8]()
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "\"") {
                i += 1
                // Let Foundation resolve the escapes of the (usually plain) text.
                let quoted = Data([UInt8(ascii: "[")] + [UInt8(ascii: "\"")] + raw + [UInt8(ascii: "\""), UInt8(ascii: "]")])
                guard let parsed = (try? JSONSerialization.jsonObject(with: quoted)) as? [String], let s = parsed.first else {
                    throw fail("bad string")
                }
                return s
            }
            raw.append(b)
            i += 1
            if b == UInt8(ascii: "\\"), i < bytes.count {
                raw.append(bytes[i])
                i += 1
            }
        }
        throw fail("unterminated string")
    }

    private mutating func array() throws -> JSONValue {
        i += 1
        var items = [JSONValue]()
        skipSpace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            items.append(try value())
            skipSpace()
            guard i < bytes.count else { throw fail("unterminated array") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            throw fail("expected , or ]")
        }
    }

    private mutating func object() throws -> JSONValue {
        i += 1
        var pairs = [(key: String, value: JSONValue)]()
        skipSpace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
        while true {
            skipSpace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected a key") }
            let key = try string()
            skipSpace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected :") }
            i += 1
            pairs.append((key, try value()))
            skipSpace()
            guard i < bytes.count else { throw fail("unterminated object") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
            throw fail("expected , or }")
        }
    }
}

// MARK: errors

/// Names the fixture file, the case and the key, so a failure says where to look.
struct FixtureReadError: Error, CustomStringConvertible {
    let file: String
    let caseName: String
    let message: String

    var description: String {
        caseName.isEmpty ? "\(file).json: \(message)" : "\(file).json case '\(caseName)': \(message)"
    }
}

// MARK: scenario accessors

/// The `scenario` object of one case, read with typed accessors. A required key that is missing, null or of the wrong type throws; there are no defaults.
/// A key that may legitimately be null (`seek`) is read with `optional...` accessors, which still fail when the key is absent.
struct Scenario {
    let file: String
    let caseName: String
    /// Where inside the scenario this accessor points (`row_inputs.paused at 7.25 s`), for messages.
    let path: String
    let value: JSONValue

    init(file: String, caseName: String, path: String = "scenario", value: JSONValue) {
        self.file = file
        self.caseName = caseName
        self.path = path
        self.value = value
    }

    private func error(_ message: String) -> FixtureReadError {
        FixtureReadError(file: file, caseName: caseName, message: message)
    }

    private func missing(_ key: String) -> FixtureReadError {
        error("\(path) has no key \"\(key)\" (keys: \(value.keys.joined(separator: ", ")))")
    }

    private func wrongType(_ key: String, expected: String, found: JSONValue) -> FixtureReadError {
        error("\(path).\(key) should be \(expected) but is \(found.kind)")
    }

    var keys: [String] { value.keys }

    func has(_ key: String) -> Bool { value[key] != nil }

    /// The raw value of a key; throws when the key is absent.
    func raw(_ key: String) throws -> JSONValue {
        guard let v = value[key] else { throw missing(key) }
        return v
    }

    func isNull(_ key: String) throws -> Bool {
        if case .null = try raw(key) { return true }
        return false
    }

    func double(_ key: String) throws -> Double {
        guard case .number(let n) = try raw(key) else { throw wrongType(key, expected: "a number", found: try raw(key)) }
        return n
    }

    func int(_ key: String) throws -> Int {
        let n = try double(key)
        guard n.rounded() == n else { throw error("\(path).\(key) should be a whole number but is \(n)") }
        return Int(n)
    }

    func string(_ key: String) throws -> String {
        guard case .string(let s) = try raw(key) else { throw wrongType(key, expected: "a string", found: try raw(key)) }
        return s
    }

    func bool(_ key: String) throws -> Bool {
        guard case .bool(let b) = try raw(key) else { throw wrongType(key, expected: "a boolean", found: try raw(key)) }
        return b
    }

    /// A number, or null for "none".
    func optionalDouble(_ key: String) throws -> Double? {
        if try isNull(key) { return nil }
        return try double(key)
    }

    func doubles(_ key: String) throws -> [Double] {
        guard case .array(let items) = try raw(key) else { throw wrongType(key, expected: "an array of numbers", found: try raw(key)) }
        return try items.enumerated().map { index, item in
            guard case .number(let n) = item else { throw error("\(path).\(key)[\(index)] should be a number but is \(item.kind)") }
            return n
        }
    }

    func ints(_ key: String) throws -> [Int] {
        try doubles(key).enumerated().map { index, n in
            guard n.rounded() == n else { throw error("\(path).\(key)[\(index)] should be a whole number but is \(n)") }
            return Int(n)
        }
    }

    func strings(_ key: String) throws -> [String] {
        guard case .array(let items) = try raw(key) else { throw wrongType(key, expected: "an array of strings", found: try raw(key)) }
        return try items.enumerated().map { index, item in
            guard case .string(let s) = item else { throw error("\(path).\(key)[\(index)] should be a string but is \(item.kind)") }
            return s
        }
    }

    /// The object under `key`, to read its own keys.
    func object(_ key: String) throws -> Scenario {
        let v = try raw(key)
        guard case .object = v else { throw wrongType(key, expected: "an object", found: v) }
        return Scenario(file: file, caseName: caseName, path: "\(path).\(key)", value: v)
    }

    /// The object under `key` or nil when it is null (`seek`).
    func optionalObject(_ key: String) throws -> Scenario? {
        if try isNull(key) { return nil }
        return try object(key)
    }

    /// The elements of an array of objects.
    func objects(_ key: String) throws -> [Scenario] {
        guard case .array(let items) = try raw(key) else { throw wrongType(key, expected: "an array of objects", found: try raw(key)) }
        return try items.enumerated().map { index, item in
            guard case .object = item else { throw error("\(path).\(key)[\(index)] should be an object but is \(item.kind)") }
            return Scenario(file: file, caseName: caseName, path: "\(path).\(key)[\(index)]", value: item)
        }
    }

    /// An object of numbers by name, in file order (`library_s`, `measured_lufs` with nulls are read with `optionalNumbersByName`).
    func numbersByName(_ key: String) throws -> [(name: String, value: Double)] {
        let o = try object(key)
        return try o.keys.map { ($0, try o.double($0)) }
    }

    func optionalNumbersByName(_ key: String) throws -> [(name: String, value: Double?)] {
        let o = try object(key)
        return try o.keys.map { ($0, try o.optionalDouble($0)) }
    }

    /// A part of the scenario decoded into a model (`TrimFields`, `[TriggerCase.Point]`). A decoding failure names the key.
    func decode<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T {
        let v = try raw(key)
        do {
            return try JSONDecoder().decode(T.self, from: v.serialized())
        } catch {
            throw self.error("\(path).\(key) does not decode as \(T.self): \(error)")
        }
    }

    /// `Scenario.decode` for an object that is already in hand (the rows of `row_inputs`).
    func decodeSelf<T: Decodable>(as type: T.Type = T.self) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: value.serialized())
        } catch {
            throw self.error("\(path) does not decode as \(T.self): \(error)")
        }
    }

    /// The entry of an object keyed by a row label (`row_inputs`). Throws naming the label when the scenario has no inputs for the row.
    func row(_ key: String, label: String) throws -> Scenario {
        let all = try object(key)
        guard all.has(label) else {
            throw error("\(path).\(key) has no entry for the row '\(label)' (entries: \(all.keys.joined(separator: " | ")))")
        }
        return try all.object(label)
    }
}

// MARK: fixture documents and cases

/// A whole fixture file as raw JSON.
struct FixtureDocument {
    let file: String
    let root: JSONValue

    nonisolated(unsafe) private static var cache = [String: FixtureDocument]()

    static func load(_ file: String) throws -> FixtureDocument {
        if let hit = cache[file] { return hit }
        let url = AudioSpec.fixtureURL(file)
        guard let data = try? Data(contentsOf: url) else { throw FixtureError.missing(url.path) }
        let root: JSONValue
        do {
            root = try JSONParser.parse(data)
        } catch {
            throw FixtureReadError(file: file, caseName: "", message: "\(error)")
        }
        let doc = FixtureDocument(file: file, root: root)
        if case .number(let found)? = root["spec_version"], Int(found) != AudioSpec.pinnedVersion {
            throw FixtureError.versionMismatch(file: file, found: Int(found), pinned: AudioSpec.pinnedVersion)
        }
        cache[file] = doc
        return doc
    }

    private func readError(_ message: String) -> FixtureReadError { FixtureReadError(file: file, caseName: "", message: message) }

    /// A number at the top of the file (`tolerance`, `tolerance_lufs`).
    func topNumber(_ key: String) throws -> Double {
        guard let v = root[key] else { throw readError("no top-level key \"\(key)\"") }
        guard case .number(let n) = v else { throw readError("top-level \"\(key)\" should be a number but is \(v.kind)") }
        return n
    }

    /// Names of the cases, `_info*` keys left out, in file order.
    var caseNames: [String] {
        (root["cases"]?.keys ?? []).filter { !$0.hasPrefix("_info") }
    }

    func `case`(_ name: String) throws -> FixtureCase {
        guard let cases = root["cases"], let v = cases[name] else {
            throw readError("no case \"\(name)\" (cases: \(caseNames.joined(separator: ", ")))")
        }
        return try FixtureCase(document: self, name: name, value: v, parent: nil)
    }

    /// Every case, nested ones (`duck_loop.cases`) included.
    func allCases() throws -> [FixtureCase] {
        try caseNames.flatMap { name -> [FixtureCase] in
            let c = try self.case(name)
            return [c] + (try c.nestedCases())
        }
    }
}

/// One case, with the tolerances that apply to it. A `tolerance` (or `tolerance_lufs`) on the case overrides the file's for that case and for
/// the cases nested inside it; a nested case may override again.
struct FixtureCase {
    let document: FixtureDocument
    /// `ducking.json`'s `duck_loop` nested case is `duck_loop/production_defaults_hold_on`.
    let name: String
    let value: JSONValue
    /// Tolerance of LUFS values (`tolerance_lufs`), resolved the same way; nil when neither the case, its parents nor the file has one.
    private let lufs: Double?
    /// Absolute tolerance of the values of this case (dB, gain, seconds as the file says).
    let tolerance: Double
    /// `tolerance_by_key` of the case (or the enclosing case): a tolerance for the named keys only, which beats `tolerance` for them.
    private let byKey: [String: Double]

    init(document: FixtureDocument, name: String, value: JSONValue, parent: FixtureCase?) throws {
        self.document = document
        self.name = name
        self.value = value
        if let own = value["tolerance_lufs"] {
            guard case .number(let n) = own else {
                throw FixtureReadError(file: document.file, caseName: name, message: "\"tolerance_lufs\" should be a number but is \(own.kind)")
            }
            lufs = n
        } else if let parent {
            lufs = parent.lufs
        } else {
            lufs = try? document.topNumber("tolerance_lufs")
        }
        var keyed = parent?.byKey ?? [:]
        if let own = value["tolerance_by_key"] {
            guard case .object(let pairs) = own else {
                throw FixtureReadError(file: document.file, caseName: name, message: "\"tolerance_by_key\" should be an object but is \(own.kind)")
            }
            for pair in pairs {
                guard case .number(let n) = pair.value else {
                    throw FixtureReadError(file: document.file, caseName: name, message: "tolerance_by_key.\(pair.key) should be a number but is \(pair.value.kind)")
                }
                keyed[pair.key] = n
            }
        }
        byKey = keyed
        if let own = value["tolerance"] {
            guard case .number(let n) = own else {
                throw FixtureReadError(file: document.file, caseName: name, message: "\"tolerance\" should be a number but is \(own.kind)")
            }
            tolerance = n
        } else if let parent {
            tolerance = parent.tolerance
        } else {
            tolerance = try document.topNumber("tolerance")
        }
    }

    var file: String { document.file }

    /// The tolerance of a named value: the case's `tolerance_by_key` entry for `key` when there is one, else the case's `tolerance`.
    func tolerance(forKey key: String) -> Double { byKey[key] ?? tolerance }

    /// Tolerance of LUFS values: the case's `tolerance_lufs`, else the enclosing case's, else the file's.
    func toleranceLufs() throws -> Double {
        guard let lufs else { throw FixtureReadError(file: file, caseName: name, message: "no `tolerance_lufs` on the case or in the file") }
        return lufs
    }

    /// The `scenario` of this case. Throws when the case has none.
    func scenario() throws -> Scenario {
        guard let s = value["scenario"] else {
            throw FixtureReadError(file: file, caseName: name, message: "has no `scenario` object: the fixture is not self-describing, re-sync the fixtures")
        }
        guard case .object = s else {
            throw FixtureReadError(file: file, caseName: name, message: "`scenario` should be an object but is \(s.kind)")
        }
        return Scenario(file: file, caseName: name, value: s)
    }

    func nestedCases() throws -> [FixtureCase] {
        guard let nested = value["cases"], case .object(let pairs) = nested else { return [] }
        return try pairs.filter { !$0.key.hasPrefix("_info") }.map {
            try FixtureCase(document: document, name: "\(name)/\($0.key)", value: $0.value, parent: self)
        }
    }

    func nested(_ key: String) throws -> FixtureCase {
        guard let nestedValue = value["cases"]?[key] else {
            throw FixtureReadError(file: file, caseName: name, message: "has no nested case \"\(key)\"")
        }
        return try FixtureCase(document: document, name: "\(name)/\(key)", value: nestedValue, parent: self)
    }
}

extension Scenario {
    /// A string that names a case of an enum (`end_action`, `play_mode`). An unknown name fails with the list of known ones.
    func named<E: RawRepresentable & CaseIterable>(_ key: String, as type: E.Type = E.self) throws -> E where E.RawValue == String {
        try named(try string(key), at: key, as: type)
    }

    func named<E: RawRepresentable & CaseIterable>(_ text: String, at key: String, as type: E.Type = E.self) throws -> E where E.RawValue == String {
        guard let e = E(rawValue: text) else {
            let known = E.allCases.map(\.rawValue).joined(separator: ", ")
            throw FixtureReadError(file: file, caseName: caseName, message: "\(path).\(key) is \"\(text)\", which is not one of: \(known)")
        }
        return e
    }

    /// `object[name]` as a number: a track's length in `library_s`, a file's loudness in `measured_lufs`.
    func number(_ key: String, named name: String) throws -> Double {
        try object(key).double(name)
    }
}
