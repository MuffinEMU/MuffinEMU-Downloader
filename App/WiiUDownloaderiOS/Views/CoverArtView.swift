import SwiftUI
import UIKit
import WUDCore

/// Fetches GameTDB box art, walking the region-folder fallback list until one exists, with an
/// in-memory cache plus URLCache on disk so scrolling the list doesn't refetch.
actor CoverArtLoader {
    static let shared = CoverArtLoader()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 150 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()
    private let images = NSCache<NSString, UIImage>()
    private var misses: Set<String> = []
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func image(for gameTDBID: String, highQuality: Bool) async -> UIImage? {
        let key = "\(gameTDBID)|\(highQuality)"
        if let cached = images.object(forKey: key as NSString) { return cached }
        if misses.contains(key) { return nil }
        if let task = inFlight[key] { return await task.value }

        let task = Task<UIImage?, Never> { [session] in
            for url in TitleMetadata.coverURLs(gameTDBID: gameTDBID, highQuality: highQuality) {
                if Task.isCancelled { return nil }
                guard let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = UIImage(data: data)
                else { continue }
                return image
            }
            return nil
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            images.setObject(result, forKey: key as NSString)
        } else {
            misses.insert(key)
        }
        return result
    }
}

/// Box art for a title, falling back to the category badge when GameTDB has none.
struct CoverArtView: View {
    let entry: TitleEntry
    var width: CGFloat = 44
    var highQuality = false
    var enabled = true

    @State private var image: UIImage?

    private var height: CGFloat { (width * 1.375).rounded() }
    private var gameTDBID: String? { TitleMetadata.shared.info(for: entry.titleID)?.gameTDBID }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: width * 0.14, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
                CategoryBadge(category: entry.category, size: width * 0.62)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: width * 0.14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: width * 0.14, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
        .task(id: "\(entry.titleID)-\(highQuality)-\(enabled)") {
            guard enabled, let gameTDBID else { image = nil; return }
            let loaded = await CoverArtLoader.shared.image(for: gameTDBID, highQuality: highQuality)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
        .accessibilityHidden(true)
    }
}
