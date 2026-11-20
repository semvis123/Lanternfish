/// Word-boundary-aware text matching shared by the name-based classifiers.
enum DeviceText {
    /// Lowercased runs of letters and digits: "Sam's iPhone" → ["sam", "s", "iphone"].
    static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// Tokens joined by single spaces and padded with a space at each end: " sam s iphone ".
    static func padded(_ s: String) -> String {
        " " + tokens(s).joined(separator: " ") + " "
    }

    /// Whether `haystack` (in `padded` form) contains any of `words`. Short words (< 5 chars) must
    /// match whole tokens; longer words and phrases match at a token start ("macbook" matches
    /// "macbookpro", "nas" doesn't match "dynastar", "ps5" doesn't match "ps55").
    static func contains(_ haystack: String, anyOf words: [String]) -> Bool {
        words.contains { w in
            let phrase = tokens(w).joined(separator: " ")
            guard !phrase.isEmpty else { return false }
            return haystack.contains(phrase.count < 5 ? " \(phrase) " : " \(phrase)")
        }
    }

    /// A service type or label without the DNS-SD decoration: "_ipp._tcp." → "ipp", "AirPlay" → "airplay".
    static func serviceStem(_ service: String) -> String {
        var v = service.lowercased()
        for suffix in ["._tcp.", "._udp.", "._tcp", "._udp"] where v.hasSuffix(suffix) {
            v.removeLast(suffix.count)
        }
        while v.hasPrefix("_") { v.removeFirst() }
        return v
    }
}
