import Foundation

/// Loads the community-maintained NUS title database (title IDs, names, regions) that the
/// upstream desktop tool bakes in at build time from https://napi.v10lator.de/db — a factual
/// title index, not app content.
///
/// That server is flaky (it resets HTTP/2 streams, which URLSession reports as "The network
/// connection was lost"), so the app never depends on it: a snapshot ships in the bundle
/// (`Resources/title_db.json`, extracted from upstream's v3.2 build by `scripts/extract_title_db.py`),
/// the last good download is cached on disk, and a live fetch only ever upgrades what's shown.
public enum TitleDatabaseLoader {
    public static let remoteURLString = "https://napi.v10lator.de/db?t=json"
    /// The upstream build script identifies itself this way; the server has been seen to
    /// treat unknown agents differently.
    static let userAgent = "NUSspliBuilder/2.1"

    public enum Source: String {
        case network, wiiubrew, cache, bundled
    }

    public struct RemoteEntry: Codable {
        let name: String
        let titleID: String
        let region: UInt8
        let key: UInt8?
        let category: UInt8

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case titleID = "TitleID"
            case region = "Region"
            case key = "Key"
            case category = "Category"
        }
    }

    public enum LoaderError: Error, LocalizedError {
        case badResponse(Int)
        case noData

        public var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "The title database server answered with HTTP \(code)."
            case .noData: return "No title database is available."
            }
        }
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wud_title_db.json")
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    public static func loadCached() throws -> [TitleEntry] {
        try decode(Data(contentsOf: cacheURL))
    }

    public static func loadBundled() throws -> [TitleEntry] {
        guard let url = Bundle.module.url(forResource: "title_db", withExtension: "json") else {
            throw LoaderError.noData
        }
        return try decode(Data(contentsOf: url))
    }

    /// Fetches a live list and caches it: napi first, then WiiUBrew's title database merged onto
    /// the best local list. Throws only when both are unreachable; callers keep what they have.
    @discardableResult
    public static func refresh() async throws -> (entries: [TitleEntry], source: Source) {
        do {
            return (try await refreshFromNapi(), .network)
        } catch {
            let napiError = error
            guard let wiki = try? await fetchWiiUBrew(), !wiki.isEmpty else { throw napiError }
            let base = (try? loadLocal().entries) ?? []
            let merged = WiiUBrewTitleSource.merge(wiki, into: base)
            try? encode(merged).write(to: cacheURL, options: .atomic)
            return (merged, .wiiubrew)
        }
    }

    static func refreshFromNapi() async throws -> [TitleEntry] {
        var request = URLRequest(url: URL(string: remoteURLString)!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw LoaderError.badResponse(status) }
        let entries = try decode(data)
        guard !entries.isEmpty else { throw LoaderError.noData }
        try? data.write(to: cacheURL, options: .atomic)
        return entries
    }

    static func fetchWiiUBrew() async throws -> [TitleEntry] {
        let (data, response) = try await session.data(from: URL(string: WiiUBrewTitleSource.rawURLString)!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200, let text = String(data: data, encoding: .utf8) else { throw LoaderError.badResponse(status) }
        return WiiUBrewTitleSource.parse(text)
    }

    /// Best local copy right away: the cached download if there is one, else the bundled snapshot.
    public static func loadLocal() throws -> (entries: [TitleEntry], source: Source) {
        if let cached = try? loadCached(), !cached.isEmpty { return (cached, .cache) }
        let bundled = try loadBundled()
        return (bundled, .bundled)
    }

    /// Kept for callers that just want entries: local first, network only if nothing local exists.
    public static func load() async throws -> [TitleEntry] {
        if let local = try? loadLocal() { return local.entries }
        return try await refresh().entries
    }

    private static func encode(_ entries: [TitleEntry]) throws -> Data {
        try JSONEncoder().encode(entries.map {
            RemoteEntry(name: $0.name, titleID: $0.titleIDHex, region: $0.region, key: $0.key, category: $0.category.rawValue)
        })
    }

    private static func decode(_ data: Data) throws -> [TitleEntry] {
        let remote = try JSONDecoder().decode([RemoteEntry].self, from: data)
        return remote.compactMap { entry in
            guard let tid = UInt64(entry.titleID, radix: 16) else { return nil }
            let category = TitleCategory(rawValue: entry.category) ?? .all
            // The database's Version field isn't a download target (upstream bakes in 0 for
            // everything); which TMD to fetch is the user's choice, defaulting to latest.
            return TitleEntry(name: entry.name, titleID: tid, region: entry.region, key: entry.key ?? 0, category: category)
        }
    }
}
