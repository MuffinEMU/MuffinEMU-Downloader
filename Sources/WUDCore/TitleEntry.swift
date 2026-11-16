import Foundation

public enum MCPRegion {
    public static let japan: UInt8 = 0x01
    public static let usa: UInt8 = 0x02
    public static let europe: UInt8 = 0x04
    public static let china: UInt8 = 0x10
    public static let korea: UInt8 = 0x20
    public static let taiwan: UInt8 = 0x40
}

/// Which well-known password the ticket's title key was originally wrapped with.
/// Only meaningful for titles that don't carry their own signed ticket on NUS,
/// where the tool falls back to generating one (see ``TitleKeyGenerator``).
public enum TitleKeyPasswordKind: UInt8, CaseIterable {
    case mypass = 0
    case nintendo
    case test
    case digits1234567890
    case lucy131211
    case fbf10
    case digits5678
    case digits1234
    case empty
    case magic

    public var password: String {
        switch self {
        case .mypass: return "mypass"
        case .nintendo: return "nintendo"
        case .test: return "test"
        case .digits1234567890: return "1234567890"
        case .lucy131211: return "Lucy131211"
        case .fbf10: return "fbf10"
        case .digits5678: return "5678"
        case .digits1234: return "1234"
        case .empty: return ""
        case .magic: return "MAGIC"
        }
    }
}

public enum TitleCategory: UInt8, Codable, CaseIterable {
    case game = 0
    case update
    case dlc
    case demo
    case all
    case disc
}

public enum TitleIDHigh {
    public static let game: UInt32 = 0x0005_0000
    public static let demo: UInt32 = 0x0005_0002
    public static let systemApp: UInt32 = 0x0005_0010
    public static let systemData: UInt32 = 0x0005_001B
    public static let systemApplet: UInt32 = 0x0005_0030
    public static let vWiiIOS: UInt32 = 0x0000_0007
    public static let vWiiSystemApp: UInt32 = 0x0007_0002
    public static let vWiiSystem: UInt32 = 0x0007_0008
    public static let dlc: UInt32 = 0x0005_000C
    public static let update: UInt32 = 0x0005_000E
}

public struct TitleEntry: Codable, Identifiable, Hashable {
    public var name: String
    public var titleID: UInt64
    public var region: UInt8
    public var key: UInt8
    public var category: TitleCategory
    public var version: Int

    public var id: UInt64 { titleID }

    public init(name: String, titleID: UInt64, region: UInt8, key: UInt8, category: TitleCategory, version: Int = -1) {
        self.name = name
        self.titleID = titleID
        self.region = region
        self.key = key
        self.category = category
        self.version = version
    }

    public var titleIDHex: String {
        String(format: "%016llX", titleID)
    }
}

/// Any version >= 0 downloads that exact TMD version. -1 means "latest".
public let versionLatest = -1

public enum TitleDatabaseHelpers {
    public static func entries(in database: [TitleEntry], category: TitleCategory) -> [TitleEntry] {
        database.filter { entry in
            guard entry.category != .disc else { return false }
            return category == .all || category == entry.category
        }
    }

    public static func formattedRegion(_ region: UInt8) -> String {
        var regions: [String] = []
        if region & MCPRegion.usa != 0 { regions.append("USA") }
        if region & MCPRegion.europe != 0 { regions.append("Europe") }
        if region & MCPRegion.japan != 0 { regions.append("Japan") }
        let primaryCount = regions.count
        if region & MCPRegion.china != 0 { regions.append("China") }
        if region & MCPRegion.korea != 0 { regions.append("Korea") }
        if region & MCPRegion.taiwan != 0 { regions.append("Taiwan") }

        switch regions.count {
        case 0: return "Unknown"
        case 3 where primaryCount == 3: return "All"
        default: return regions.joined(separator: "/")
        }
    }

    public static func formattedKind(forTitleID titleID: UInt64) -> String {
        switch UInt32(titleID >> 32) {
        case TitleIDHigh.game: return "Game"
        case TitleIDHigh.demo: return "Demo"
        case TitleIDHigh.systemApp: return "System App"
        case TitleIDHigh.systemData: return "System Data"
        case TitleIDHigh.systemApplet: return "System Applet"
        case TitleIDHigh.vWiiIOS: return "vWii IOS"
        case TitleIDHigh.vWiiSystemApp: return "vWii System App"
        case TitleIDHigh.vWiiSystem: return "vWii System"
        case TitleIDHigh.dlc: return "DLC"
        case TitleIDHigh.update: return "Update"
        default: return "Unknown"
        }
    }

    public static func titleIDHigh(_ tid: UInt64) -> UInt32 { UInt32(tid >> 32) }
    public static func titleIDLow(_ tid: UInt64) -> UInt32 { UInt32(tid & 0xFFFF_FFFF) }

    static func relatedTypeTargets(forHigh high: UInt32) -> [UInt32] {
        switch high {
        case TitleIDHigh.game: return [TitleIDHigh.dlc, TitleIDHigh.update]
        case TitleIDHigh.dlc: return [TitleIDHigh.game, TitleIDHigh.update]
        case TitleIDHigh.update: return [TitleIDHigh.game, TitleIDHigh.dlc]
        default: return []
        }
    }

    /// Finds the best-matching sibling title (an update/DLC/base game for the same low ID),
    /// preferring one in the same region.
    public static func findRelatedTitle(
        for source: TitleEntry,
        targetHigh: UInt32,
        in database: [TitleEntry],
        excluding exclude: Set<UInt64> = []
    ) -> TitleEntry? {
        let sourceLow = titleIDLow(source.titleID)
        var best: TitleEntry?
        var bestScore = 3

        for entry in database {
            guard entry.category != .disc else { continue }
            guard titleIDHigh(entry.titleID) == targetHigh else { continue }
            guard titleIDLow(entry.titleID) == sourceLow else { continue }
            if exclude.contains(entry.titleID) { continue }

            let score: Int
            if entry.region == source.region {
                score = 0
            } else if entry.region & source.region != 0 {
                score = 1
            } else {
                score = 2
            }

            if best == nil || score < bestScore || (score == bestScore && entry.titleID < best!.titleID) {
                best = entry
                bestScore = score
            }
        }
        return best
    }

    public static func entry(forTitleID tid: UInt64, in database: [TitleEntry]) -> TitleEntry? {
        database.first { $0.category != .disc && $0.titleID == tid }
    }
}
