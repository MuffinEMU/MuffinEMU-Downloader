import Foundation

/// Second live source for the title list: WiiUBrew's community-maintained Title database page,
/// read as raw wikitext. Used when napi.v10lator.de is down (it has been, for every client).
/// Covers games, demos, DLC and updates with names and regions; it has no title-key password
/// field, so entries merged from here keep the bundled list's value where one exists.
public enum WiiUBrewTitleSource {
    public static let rawURLString = "https://wiiubrew.org/w/index.php?title=Title_database&action=raw"

    /// Parses the four title tables this app cares about. Columns are found by header name
    /// because each table orders them differently.
    public static func parse(_ wikitext: String) -> [TitleEntry] {
        var entries: [TitleEntry] = []
        var seen: Set<UInt64> = []
        var headers: [String] = []
        var cells: [String] = []

        func flushRow() {
            defer { cells = [] }
            guard let idIndex = headers.firstIndex(of: "title id"), idIndex < cells.count else { return }
            let hex = cells[idIndex].replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces)
            guard hex.count == 16, let tid = UInt64(hex, radix: 16) else { return }

            let category: TitleCategory
            switch UInt32(tid >> 32) {
            case TitleIDHigh.game: category = .game
            case TitleIDHigh.update: category = .update
            case TitleIDHigh.dlc: category = .dlc
            case TitleIDHigh.demo: category = .demo
            default: return
            }
            guard !seen.contains(tid) else { return }

            let nameIndex = headers.firstIndex(of: "name") ?? headers.firstIndex(of: "description")
            let name = nameIndex.flatMap { $0 < cells.count ? cleanName(cells[$0]) : nil } ?? ""
            guard !name.isEmpty else { return }
            let regionIndex = headers.firstIndex(of: "region")
            let region = regionIndex.flatMap { $0 < cells.count ? regionMask(cells[$0]) : nil } ?? 0

            seen.insert(tid)
            entries.append(TitleEntry(name: name, titleID: tid, region: region, key: 0, category: category))
        }

        for rawLine in wikitext.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("{|") {
                headers = []
                cells = []
            } else if line.hasPrefix("!") {
                headers += line.dropFirst().components(separatedBy: "!!").map {
                    $0.trimmingCharacters(in: .whitespaces).lowercased()
                }
            } else if line.hasPrefix("|-") || line.hasPrefix("|}") {
                flushRow()
            } else if line.hasPrefix("|") {
                cells += line.dropFirst().components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        flushRow()
        return entries
    }

    /// "[[Page|Shown]]" → "Shown", "[[Page]]" → "Page", strips refs/HTML and trailing notes in
    /// parentheses that are only wiki links.
    static func cleanName(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"<ref[^>]*>.*?</ref>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[\[[^\]|]*\|([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[\[([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "'''", with: "").replacingOccurrences(of: "''", with: "")
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func regionMask(_ raw: String) -> UInt8 {
        let upper = raw.uppercased()
        if upper.hasPrefix("ALL") { return MCPRegion.japan | MCPRegion.usa | MCPRegion.europe }
        var mask: UInt8 = 0
        if upper.contains("USA") { mask |= MCPRegion.usa }
        if upper.contains("EUR") { mask |= MCPRegion.europe }
        if upper.contains("JPN") { mask |= MCPRegion.japan }
        if upper.contains("CHN") { mask |= MCPRegion.china }
        if upper.contains("KOR") { mask |= MCPRegion.korea }
        if upper.contains("TWN") { mask |= MCPRegion.taiwan }
        return mask
    }

    /// Adds WiiUBrew titles missing from `base` (typically the bundled/cached napi list). Existing
    /// entries win: napi's names are cleaner and they carry the title-key password index.
    public static func merge(_ wiki: [TitleEntry], into base: [TitleEntry]) -> [TitleEntry] {
        let known = Set(base.map(\.titleID))
        // Many WiiUBrew rows leave Region blank; a sibling (same game, other type) usually has it.
        var regionByLow: [UInt32: UInt8] = [:]
        for entry in base + wiki where entry.region != 0 {
            regionByLow[UInt32(entry.titleID & 0xFFFF_FFFF)] = regionByLow[UInt32(entry.titleID & 0xFFFF_FFFF)] ?? entry.region
        }
        let additions = wiki.filter { !known.contains($0.titleID) }.map { entry -> TitleEntry in
            guard entry.region == 0, let region = regionByLow[UInt32(entry.titleID & 0xFFFF_FFFF)] else { return entry }
            var filled = entry
            filled.region = region
            return filled
        }
        return base + additions
    }
}
