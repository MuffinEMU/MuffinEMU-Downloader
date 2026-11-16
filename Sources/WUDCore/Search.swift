import Foundation

/// Token-based fuzzy title search: every word in the query must fuzzy-match some word in the
/// title (or the query matches the title ID substring directly).
public enum TitleSearch {
    public static func normalize(_ text: String) -> String {
        var out = ""
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(Character(scalar).lowercased().unicodeScalars.first!)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    public static func matches(query: String, titleName: String, titleIDHex: String) -> Bool {
        guard !query.isEmpty else { return true }

        if titleIDHex.lowercased().contains(query.lowercased()) { return true }

        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return false }

        let queryTokens = normalizedQuery.split(separator: " ").map(String.init)
        let titleTokens = normalize(titleName).split(separator: " ").map(String.init)
        guard !titleTokens.isEmpty else { return false }

        return queryTokens.allSatisfy { queryToken in
            titleTokens.contains { fuzzyMatch(queryToken, $0) }
        }
    }

    /// Subsequence fuzzy match (every character of `needle` appears in `haystack` in order) —
    /// the same tolerant behavior as the upstream tool's fuzzy-search dependency.
    static func fuzzyMatch(_ needle: String, _ haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var haystackIndex = haystack.startIndex
        for ch in needle {
            guard let found = haystack[haystackIndex...].firstIndex(where: { $0 == ch }) else { return false }
            haystackIndex = haystack.index(after: found)
        }
        return true
    }
}
