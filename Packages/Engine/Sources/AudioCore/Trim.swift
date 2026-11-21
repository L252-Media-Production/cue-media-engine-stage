import Foundation

/// How a stored value is changed by an edit.
public enum Change<Value: Equatable>: Equatable {
    case keep
    case clear
    case set(Value)
}

/// The edge of a trim: a fade (the default) or a cut.
public enum TrimEdge: Equatable {
    case fade
    case cut
}

/// The player settings a trim falls back on (docs/audio-spec-1.md, "Fade or cut at B", "Fade in at A").
public struct TrimPolicy: Equatable {
    /// The out-fade at B when a track has no length of its own, in ms.
    public var defaultFadeOutMs: Int
    /// The fade-in at A when a track has no length of its own, in ms (0 = none).
    public var defaultFadeInMs: Int

    public init(defaultFadeOutMs: Int, defaultFadeInMs: Int) {
        self.defaultFadeOutMs = max(0, defaultFadeOutMs)
        self.defaultFadeInMs = max(0, min(Trim.fadeRangeMs.upperBound, defaultFadeInMs))
    }
}

/// The part of a file that plays: where it starts (A, the In point) and ends (B, the Out point), in seconds of the file.
public struct TrimWindow: Equatable {
    public var start: Double
    public var end: Double
    public var length: Double { end - start }
}

/// One change to a stored trim. Fields left at `.keep` are not touched.
public struct TrimEdit: Equatable {
    public var inPoint: Change<Double> = .keep
    public var outPoint: Change<Double> = .keep
    public var endEdge: Change<TrimEdge> = .keep
    public var fadeOutMs: Change<Int> = .keep
    public var fadeInMs: Change<Int> = .keep
    public var startEdge: Change<TrimEdge> = .keep

    public init() {}
}

/// What is stored for one track: A, B, the edges and the fade lengths. All values are stored the way the spec's fixtures show them:
/// points rounded to 0.01 s, an In point under 0.01 s or an Out point within 0.01 s of the end not kept, a fade length held to the part that plays.
public struct Trim: Equatable {
    /// A window shorter than this is not allowed (an edit is refused; an old stored one falls back).
    public static let minWindowSeconds = 0.5
    /// Allowed length of a fade, in ms. (Not stated by the spec text; the fixtures only show 50 refused and 2500 accepted, 20000 refused.)
    public static let fadeRangeMs = 100...10_000

    public var inPoint: Double?
    public var outPoint: Double?
    public var endsWithCut = false
    public var fadeOutMs: Int?
    public var fadeInMs: Int?
    public var fadesInAtStart = false

    public init(inPoint: Double? = nil, outPoint: Double? = nil, endsWithCut: Bool = false, fadeOutMs: Int? = nil, fadeInMs: Int? = nil, fadesInAtStart: Bool = false) {
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.endsWithCut = endsWithCut
        self.fadeOutMs = fadeOutMs
        self.fadeInMs = fadeInMs
        self.fadesInAtStart = fadesInAtStart
    }

    /// The window that plays, for a file `fileLength` seconds long. A is held `minWindowSeconds` before the end; a window shorter than that falls back to end at the end of the file.
    public func window(fileLength: Double) -> TrimWindow {
        let start = max(0, min(inPoint ?? 0, max(0, fileLength - Self.minWindowSeconds)))
        var end = min(fileLength, outPoint ?? fileLength)
        if end < start + Self.minWindowSeconds { end = fileLength }
        return TrimWindow(start: start, end: end)
    }

    /// The out-fade length at B: the track's own, else the player's default.
    public func fadeOutMs(policy: TrimPolicy) -> Int { fadeOutMs ?? policy.defaultFadeOutMs }

    /// The fade-in length: the track's own, else the player's default (whether it is applied is `fadeInAppliedMs`).
    public func fadeInMsEffective(policy: TrimPolicy) -> Int { fadeInMs ?? policy.defaultFadeInMs }

    /// The fade-in that is applied on a start at A: the effective length while the start edge is a fade, else 0.
    public func fadeInAppliedMs(policy: TrimPolicy) -> Int { fadesInAtStart ? fadeInMsEffective(policy: policy) : 0 }

    /// Applies an edit to a file of `fileLength` seconds. Returns false, and changes nothing, when the edit is refused
    /// (a fade length out of range, or a window under `minWindowSeconds`).
    @discardableResult
    public mutating func apply(_ edit: TrimEdit, fileLength: Double) -> Bool {
        var t = self
        func point(_ change: Change<Double>, _ current: Double?) -> Double?? {
            switch change {
            case .keep: return .some(current)
            case .clear: return .some(nil)
            case .set(let v):
                let clean = v.isNaN ? 0 : max(0, v)
                let rounded = clean.isFinite ? Self.round2(clean) : clean
                return .some(min(rounded, Self.round2(fileLength)))
            }
        }
        func length(_ change: Change<Int>, _ current: Int?) -> Int?? {
            switch change {
            case .keep: return .some(current)
            case .clear: return .some(nil)
            case .set(let ms): return Self.fadeRangeMs.contains(ms) ? .some(ms) : nil
            }
        }
        guard let inP = point(edit.inPoint, t.inPoint), let outP = point(edit.outPoint, t.outPoint),
              let fo = length(edit.fadeOutMs, t.fadeOutMs), let fi = length(edit.fadeInMs, t.fadeInMs)
        else { return false }
        t.inPoint = inP
        t.outPoint = outP
        t.fadeOutMs = fo
        t.fadeInMs = fi
        switch edit.endEdge {
        case .keep: break
        case .clear, .set(.fade): t.endsWithCut = false
        case .set(.cut): t.endsWithCut = true
        }
        switch edit.startEdge {
        case .keep: break
        case .clear, .set(.cut): t.fadesInAtStart = false
        case .set(.fade): t.fadesInAtStart = true
        }

        if let a = t.inPoint, a <= 0.01 { t.inPoint = nil }
        if let b = t.outPoint, b >= fileLength - 0.01 { t.outPoint = nil }
        if let a = t.inPoint, let b = t.outPoint, b < a + Self.minWindowSeconds { return false }
        if t.outPoint == nil { t.fadeOutMs = nil }
        if let f = t.fadeOutMs, let b = t.outPoint {
            t.fadeOutMs = max(Self.fadeRangeMs.lowerBound, min(f, Int((b - (t.inPoint ?? 0)) * 1000)))
        }
        if let f = t.fadeInMs {
            let top = t.outPoint ?? fileLength
            t.fadeInMs = max(Self.fadeRangeMs.lowerBound, min(f, Int((top - (t.inPoint ?? 0)) * 1000)))
        }
        if t.inPoint == nil, t.outPoint == nil, !t.fadesInAtStart, t.fadeInMs == nil { t = Trim() }
        self = t
        return true
    }

    /// Seconds rounded to 0.01.
    public static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}
