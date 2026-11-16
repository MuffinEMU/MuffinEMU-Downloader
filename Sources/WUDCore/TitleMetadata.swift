import Foundation

/// Descriptive info for a title: GameTDB's synopsis/credits and cover art, plus the known TMD
/// versions from the WiiUBrew title database. Built offline by `scripts/build_metadata.py` and
/// shipped as `Resources/title_metadata.json`; cover images themselves are fetched from
/// art.gametdb.com on demand.
public struct GameInfo: Hashable {
    public let gameTDBID: String
    public let title: String
    public let synopsis: String?
    public let developer: String?
    public let publisher: String?
    public let year: Int?
    public let genres: [String]
}

public final class TitleMetadata {
    public static let shared = TitleMetadata()

    private struct File: Decodable {
        struct TitleRow: Decodable {
            let g: String?
            let v: [Int]?
        }
        struct GameRow: Decodable {
            let t: String
            let s: String?
            let d: String?
            let p: String?
            let y: Int?
            let r: String?
        }
        let titles: [String: TitleRow]
        let games: [String: GameRow]
    }

    private let titles: [UInt64: File.TitleRow]
    private let games: [String: File.GameRow]

    private init() {
        guard let url = Bundle.module.url(forResource: "title_metadata", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            titles = [:]
            games = [:]
            return
        }
        var byID: [UInt64: File.TitleRow] = [:]
        for (hex, row) in file.titles {
            if let tid = UInt64(hex, radix: 16) { byID[tid] = row }
        }
        titles = byID
        games = file.games
    }

    /// The base game's title ID for an update/DLC/demo-style sibling (same low half).
    public static func baseGameID(for titleID: UInt64) -> UInt64 {
        let high = UInt32(titleID >> 32)
        guard high == TitleIDHigh.update || high == TitleIDHigh.dlc else { return titleID }
        return (UInt64(TitleIDHigh.game) << 32) | (titleID & 0xFFFF_FFFF)
    }

    public func info(for titleID: UInt64) -> GameInfo? {
        let row = titles[titleID] ?? titles[Self.baseGameID(for: titleID)]
        guard let gid = row?.g ?? titles[Self.baseGameID(for: titleID)]?.g, let game = games[gid] else { return nil }
        return GameInfo(
            gameTDBID: gid,
            title: game.t,
            synopsis: game.s?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            developer: game.d,
            publisher: game.p,
            year: game.y,
            genres: game.r?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).capitalized } ?? []
        )
    }

    /// TMD versions WiiUBrew has seen for this exact title ID, ascending. Empty when unknown.
    public func knownVersions(for titleID: UInt64) -> [Int] {
        titles[titleID]?.v ?? []
    }

    /// Candidate cover URLs, best first. GameTDB keys art by region folder; the 4th character of
    /// the ID is the region (E = USA, P = Europe, J = Japan), so that folder is tried first.
    public static func coverURLs(gameTDBID id: String, highQuality: Bool) -> [URL] {
        let kind = highQuality ? "coverHQ" : "cover"
        let regionChar = id.count >= 4 ? id[id.index(id.startIndex, offsetBy: 3)] : "E"
        var folders: [String]
        switch regionChar {
        case "P": folders = ["EN", "FR", "DE", "ES", "IT", "NL", "US"]
        case "J": folders = ["JA", "US", "EN"]
        case "K": folders = ["KO", "US", "EN"]
        default: folders = ["US", "EN", "JA"]
        }
        var urls = folders.compactMap { URL(string: "https://art.gametdb.com/wiiu/\(kind)/\($0)/\(id).jpg") }
        if highQuality {
            urls += coverURLs(gameTDBID: id, highQuality: false)
        }
        return urls
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
