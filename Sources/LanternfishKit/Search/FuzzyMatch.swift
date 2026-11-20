import Foundation

// MARK: - Searchable text

/// A string prepared for fuzzy matching: case- and diacritic-folded characters, plus which
/// positions start a word. Build once per candidate, match many times.
public struct FuzzyText: Sendable {
    public let original: String
    let folded: [Character]
    /// Per character: bonus for matching there (word starts, camelCase humps).
    let boundary: [Int16]

    public init(_ string: String) {
        original = string
        let chars = Array(string)
        var folded: [Character] = []
        folded.reserveCapacity(chars.count)
        for c in chars { folded.append(Fuzzy.fold(c)) }
        self.folded = folded
        var boundary = [Int16](repeating: 0, count: chars.count)
        for i in chars.indices {
            if i == 0 {
                boundary[i] = Fuzzy.bonusStart
            } else {
                let prev = chars[i - 1]
                let c = chars[i]
                if Fuzzy.isSeparator(prev) {
                    boundary[i] = Fuzzy.bonusBoundary
                } else if c.isUppercase, prev.isLowercase {
                    boundary[i] = Fuzzy.bonusCamel
                } else if c.isNumber, prev.isLetter {
                    boundary[i] = Fuzzy.bonusCamel
                }
            }
        }
        self.boundary = boundary
    }

    public var isEmpty: Bool { folded.isEmpty }
}

/// A query split into whitespace-separated tokens, folded like `FuzzyText`.
public struct FuzzyQuery: Sendable {
    public let raw: String
    let tokens: [[Character]]

    public init(_ string: String) {
        raw = string
        tokens = string.split(whereSeparator: \.isWhitespace).map { $0.map(Fuzzy.fold) }
    }

    public var isEmpty: Bool { tokens.isEmpty }
}

/// Result of matching one pattern against one string.
public struct FuzzyMatch: Sendable, Equatable {
    public var score: Int
    /// Matched character offsets in the original string (`Array(string)` indices), ascending.
    public var positions: [Int]
}

/// Result of matching a whole query against several fields of an item.
public struct FuzzyFieldsMatch: Sendable, Equatable {
    public var score: Int
    /// Matched character offsets per field index.
    public var positions: [Int: [Int]]
}

// MARK: - Matcher

/// Subsequence fuzzy matching with fzf-style scoring: consecutive runs and matches at word
/// starts score high, gaps and late starts cost a little, exact and prefix matches win.
public enum Fuzzy {
    private static let scoreMatch = 16
    fileprivate static let bonusStart: Int16 = 10
    fileprivate static let bonusBoundary: Int16 = 8
    fileprivate static let bonusCamel: Int16 = 7
    private static let bonusConsecutive = 6
    private static let penaltyGapStart = 3
    private static let penaltyGapExtension = 1
    private static let bonusExact = 40
    private static let bonusPrefix = 20

    private static let separators: Set<Character> = [
        " ", "-", "_", ".", ":", "/", "(", ")", "'", "’", ",", "@", "·", "—",
    ]

    fileprivate static func isSeparator(_ c: Character) -> Bool { separators.contains(c) }

    fileprivate static func fold(_ c: Character) -> Character {
        if c.isASCII { return Character(c.lowercased()) }
        let s = String(c).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return s.count == 1 ? s.first! : c
    }

    /// Matches one pattern (no tokenizing) against `candidate`.
    public static func match(_ pattern: String, in candidate: String) -> FuzzyMatch? {
        match(pattern.map(fold), in: FuzzyText(candidate))
    }

    /// Matches one token against prepared text. nil when the token isn't a subsequence.
    private static func match(_ p: [Character], in text: FuzzyText) -> FuzzyMatch? {
        let t = text.folded
        guard !p.isEmpty else { return FuzzyMatch(score: 0, positions: []) }
        guard p.count <= t.count else { return nil }

        // Forward pass: earliest end of a subsequence match.
        var pi = 0
        var end = -1
        for (i, c) in t.enumerated() where c == p[pi] {
            pi += 1
            if pi == p.count {
                end = i
                break
            }
        }
        guard end >= 0 else { return nil }

        // Backward pass from that end: the shortest window containing the match.
        var start = end
        pi = p.count - 1
        var i = end
        while i >= 0 {
            if t[i] == p[pi] {
                if pi == 0 {
                    start = i
                    break
                }
                pi -= 1
            }
            i -= 1
        }

        var best: FuzzyMatch?
        func consider(_ m: FuzzyMatch?) {
            guard let m, isAcceptable(m.positions, text: text), m.score > best?.score ?? .min else { return }
            best = m
        }
        consider(alignment(p, t: t, text: text, from: start))
        // Contiguous occurrences (e.g. at a later word start) can beat the compact window.
        var s = 0
        while s + p.count <= t.count {
            if t[s] == p[0], Array(t[s..<s + p.count]) == p {
                let positions = Array(s..<s + p.count)
                consider(FuzzyMatch(score: score(positions, text: text, patternCount: p.count), positions: positions))
            }
            s += 1
        }
        // Word-start greedy alignment: prefer each pattern character at a boundary when possible.
        consider(boundaryAlignment(p, t: t, text: text))
        return best
    }

    /// Rejects scattered matches: every run of consecutive matched characters has to start a
    /// word or be at least two characters long ("nas" matches "truenas" and "Network Attached
    /// Storage", not "Sichuan AI-Link Smart").
    private static func isAcceptable(_ positions: [Int], text: FuzzyText) -> Bool {
        var i = 0
        while i < positions.count {
            var j = i
            while j + 1 < positions.count, positions[j + 1] == positions[j] + 1 { j += 1 }
            if j == i, text.boundary[positions[i]] == 0 { return false }
            i = j + 1
        }
        return true
    }

    /// Greedy forward alignment starting at `from`.
    private static func alignment(_ p: [Character], t: [Character], text: FuzzyText, from: Int) -> FuzzyMatch {
        var positions: [Int] = []
        positions.reserveCapacity(p.count)
        var pi = 0
        var i = from
        while i < t.count, pi < p.count {
            if t[i] == p[pi] {
                positions.append(i)
                pi += 1
            }
            i += 1
        }
        return FuzzyMatch(score: score(positions, text: text, patternCount: p.count), positions: positions)
    }

    /// Greedy alignment that jumps to the next word start holding the wanted character when there
    /// is one (so "sn" in "Sam's NAS" picks the "N"), else takes the next occurrence.
    private static func boundaryAlignment(_ p: [Character], t: [Character], text: FuzzyText) -> FuzzyMatch? {
        var positions: [Int] = []
        var i = 0
        for (k, c) in p.enumerated() {
            let remaining = p.count - k - 1
            var pick: Int?
            var firstPlain: Int?
            var j = i
            // Consecutive continuation wins outright.
            if let last = positions.last, last + 1 < t.count - remaining, t[last + 1] == c {
                pick = last + 1
            } else {
                while j < t.count - remaining {
                    if t[j] == c {
                        if firstPlain == nil { firstPlain = j }
                        if text.boundary[j] > 0 {
                            pick = j
                            break
                        }
                    }
                    j += 1
                }
            }
            guard let at = pick ?? firstPlain else { return nil }
            positions.append(at)
            i = at + 1
        }
        // The jumps may have made the rest unmatchable; verify it is still a full match.
        guard positions.count == p.count else { return nil }
        return FuzzyMatch(score: score(positions, text: text, patternCount: p.count), positions: positions)
    }

    private static func score(_ positions: [Int], text: FuzzyText, patternCount: Int) -> Int {
        guard !positions.isEmpty else { return 0 }
        var total = 0
        var prev = -2
        var runBonus = 0
        for (k, pos) in positions.enumerated() {
            total += scoreMatch
            var b = Int(text.boundary[pos])
            if k == 0 { b *= 2 }
            if pos == prev + 1 {
                // Inside a run: keep the run's starting bonus alive, at least the consecutive bonus.
                runBonus = max(runBonus, bonusConsecutive)
                b = max(b, runBonus)
            } else {
                runBonus = b
                if k > 0 {
                    let gap = pos - prev - 1
                    total -= penaltyGapStart + penaltyGapExtension * min(gap - 1, 12)
                }
            }
            total += b
            prev = pos
        }
        // Late starts cost a little.
        total -= min(positions[0], 15)
        if positions.count == text.folded.count, patternCount == text.folded.count {
            total += bonusExact
        } else if positions[0] == 0, positions.last == patternCount - 1 {
            total += bonusPrefix
        }
        // Among equal matches, shorter candidates win slightly.
        total -= min(text.folded.count / 16, 4)
        return total
    }

    /// Matches every query token against the best of `fields` (weighted by `weights`, in percent;
    /// missing weights count as 100). Every token has to match some field.
    public static func match(_ query: FuzzyQuery, fields: [FuzzyText], weights: [Int] = []) -> FuzzyFieldsMatch? {
        guard !query.isEmpty else { return FuzzyFieldsMatch(score: 0, positions: [:]) }
        var total = 0
        var positions: [Int: [Int]] = [:]
        for token in query.tokens {
            var best: (score: Int, field: Int, positions: [Int])?
            for (f, text) in fields.enumerated() where !text.isEmpty {
                guard let m = match(token, in: text) else { continue }
                let w = f < weights.count ? weights[f] : 100
                let s = m.score * w / 100
                if s > best?.score ?? .min { best = (s, f, m.positions) }
            }
            guard let best else { return nil }
            total += best.score
            positions[best.field, default: []].append(contentsOf: best.positions)
        }
        for (k, v) in positions { positions[k] = Array(Set(v)).sorted() }
        return FuzzyFieldsMatch(score: total, positions: positions)
    }
}

// MARK: - Typed hosts

/// What a typed query means as a network target: an IPv4 address or a hostname.
public enum HostQuery: Equatable, Sendable {
    case ip(IPv4Address)
    case hostname(String)

    /// The host as typed (address or name), without scheme, path or port.
    public var host: String {
        switch self {
        case .ip(let ip): ip.description
        case .hostname(let h): h
        }
    }

    /// Parses "192.168.1.4", "nas.local", "example.com", "http://router.lan/admin".
    /// Hostnames need a dot (single words are search terms, not hosts) and a plausible last label.
    public static func parse(_ query: String) -> HostQuery? {
        var s = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let colon = s.lastIndex(of: ":"), s[s.index(after: colon)...].allSatisfy(\.isNumber) {
            s = String(s[..<colon])
        }
        if s.hasSuffix(".") { s.removeLast() }
        if let ip = IPv4Address(s) { return .ip(ip) }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, s.count <= 253 else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        for l in labels {
            guard !l.isEmpty, l.count <= 63, l.allSatisfy(allowed.contains),
                l.first != "-", l.last != "-"
            else { return nil }
        }
        // All-numeric names are half-typed addresses ("192.168"), not hosts.
        guard let tld = labels.last, tld.count >= 2, tld.contains(where: \.isLetter) else { return nil }
        return .hostname(s)
    }
}
