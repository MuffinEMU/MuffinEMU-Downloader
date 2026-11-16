import Foundation

/// Reports progress back to whatever's driving a download (a SwiftUI view model, a test, etc.).
/// Mirrors the upstream tool's reporter interface so the orchestration logic in ``Downloader``
/// stays UI-agnostic.
public protocol ProgressReporter: AnyObject {
    func setGameTitle(_ title: String)
    func updateDownloadProgress(downloaded: Int64, filename: String)
    func updateDecryptionProgress(_ progress: Double)
    func setDownloadSize(_ size: Int64)
    func resetTotals()
    func markFileAsDone(_ filename: String)
    func setTotalDownloaded(_ downloaded: Int64, forFile filename: String)
    func setStartTime(_ date: Date)
    var isCancelled: Bool { get }
    /// Blocks (async) while paused; returns false if cancelled while waiting.
    func waitIfPaused() async -> Bool
}

public struct DownloadOptions {
    public var expectedSize: Int64 = 0
    public var doRetries: Bool = true
    public var allowResume: Bool = true
    public var segmentSize: Int64 = 0
    public var userAgent: String = "MuffinDownloader"
    public var validate: ((URL) throws -> Void)?

    public init(expectedSize: Int64 = 0, doRetries: Bool = true, allowResume: Bool = true, segmentSize: Int64 = 0, userAgent: String = "MuffinDownloader", validate: ((URL) throws -> Void)? = nil) {
        self.expectedSize = expectedSize
        self.doRetries = doRetries
        self.allowResume = allowResume
        self.segmentSize = segmentSize
        self.userAgent = userAgent
        self.validate = validate
    }
}

/// Thin async HTTP layer over URLSession that talks to Nintendo's public NUS/CCS download
/// endpoints — the same unauthenticated GET/Range requests any web browser or the original
/// desktop tool makes. Handles resumable, integrity-checked downloads to disk.
public final class NUSSession {
    public enum SessionError: Error {
        case cancelled
        case httpStatus(Int, attempts: Int)
        case sizeMismatch(expected: Int64, got: Int64)
        case sourceChangedWhileResuming
        case rangeMismatch
        case badResponse
    }

    private let session: URLSession
    private let maxRetries = 5
    private let retryDelay: UInt64 = 5_000_000_000

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        // Files download several at a time and large ones split into ranged segments, so allow
        // enough sockets to the CDN for both.
        config.httpMaximumConnectionsPerHost = 16
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    /// Fetches a whole small resource into memory (used for the cetk cert probe and TMD size checks).
    public func download(urlString: String) async throws -> [UInt8] {
        guard let url = URL(string: urlString) else { throw SessionError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SessionError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1, attempts: 1)
        }
        return [UInt8](data)
    }

    /// Resumable, journal-verified download of `urlString` to `destination`.
    public func downloadFile(urlString: String, to destination: URL, options: DownloadOptions, progress: ProgressReporter?) async throws {
        let basename = destination.lastPathComponent

        if FileManager.default.fileExists(atPath: destination.path) {
            if (try? validateExisting(destination, options: options)) != nil {
                progress?.setTotalDownloaded(options.expectedSize, forFile: basename)
                progress?.markFileAsDone(basename)
                return
            }
            try? FileManager.default.removeItem(at: destination)
        }

        if options.allowResume, options.expectedSize >= Self.segmentedThreshold,
           !FileManager.default.fileExists(atPath: DownloadStateStore.stateURL(for: destination).path) {
            do {
                try await downloadSegmented(urlString: urlString, to: destination, options: options, progress: progress)
                return
            } catch SegmentedError.rangesUnsupported {
                SegmentedState.remove(for: destination)
                // Fall through to the single-stream path.
            }
        }

        var attempt = 1
        while attempt <= maxRetries {
            if let progress, !(await progress.waitIfPaused()) { throw SessionError.cancelled }

            let partURL = DownloadStateStore.partURL(for: destination)
            let stateURL = DownloadStateStore.stateURL(for: destination)
            var (state, existingOffset) = try prepareState(destination: destination, partURL: partURL, stateURL: stateURL, urlString: urlString, options: options)

            guard let url = URL(string: urlString) else { throw SessionError.badResponse }
            var request = URLRequest(url: url)
            request.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")
            if existingOffset > 0 {
                request.setValue("bytes=\(existingOffset)-", forHTTPHeaderField: "Range")
            }

            do {
                let (http, chunkStream, dataTask) = try await session.chunkedData(for: request)

                if existingOffset > 0, http.statusCode == 206 {
                    guard let start = rangeStart(http), start == existingOffset else {
                        DownloadStateStore.cleanupPartial(destination: destination)
                        attempt = try retryOrThrow(attempt, options, SessionError.rangeMismatch)
                        continue
                    }
                } else if existingOffset > 0, http.statusCode == 200 {
                    DownloadStateStore.cleanupPartial(destination: destination)
                    (state, existingOffset) = try prepareState(destination: destination, partURL: partURL, stateURL: stateURL, urlString: urlString, options: options)
                }

                guard http.statusCode == 200 || http.statusCode == 206 else {
                    attempt = try retryOrThrow(attempt, options, SessionError.httpStatus(http.statusCode, attempts: attempt))
                    continue
                }

                let expectedSize = resolveExpectedSize(http: http, existingOffset: existingOffset, expected: options.expectedSize)
                if var s = state {
                    if s.expectedSize > 0, expectedSize > 0, s.expectedSize != expectedSize {
                        DownloadStateStore.cleanupPartial(destination: destination)
                        attempt = try retryOrThrow(attempt, options, SessionError.sizeMismatch(expected: s.expectedSize, got: expectedSize))
                        continue
                    }
                    if expectedSize > 0 { s.expectedSize = expectedSize }
                    if let lastModified = http.value(forHTTPHeaderField: "Last-Modified") {
                        if let prior = s.lastModified, prior != lastModified, existingOffset > 0 {
                            DownloadStateStore.cleanupPartial(destination: destination)
                            attempt = try retryOrThrow(attempt, options, SessionError.sourceChangedWhileResuming)
                            continue
                        }
                        s.lastModified = lastModified
                    }
                    if let etag = http.value(forHTTPHeaderField: "ETag") {
                        if let prior = s.eTag, prior != etag, existingOffset > 0 {
                            DownloadStateStore.cleanupPartial(destination: destination)
                            attempt = try retryOrThrow(attempt, options, SessionError.sourceChangedWhileResuming)
                            continue
                        }
                        s.eTag = etag
                    }
                    try DownloadStateStore.save(s, to: stateURL)
                    state = s
                }

                if !FileManager.default.fileExists(atPath: partURL.path) {
                    FileManager.default.createFile(atPath: partURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: partURL)
                if existingOffset == 0 { try handle.truncate(atOffset: 0) }
                try handle.seek(toOffset: UInt64(existingOffset))

                let stateWriter = state != nil ? try ResumeStateWriter(handle: handle, state: state!, stateURL: stateURL) : nil

                progress?.setTotalDownloaded(existingOffset, forFile: basename)
                var buffer = Data()
                buffer.reserveCapacity(Self.writeBlockSize)

                do {
                    for try await chunk in chunkStream {
                        if let progress, !(await progress.waitIfPaused()) { throw SessionError.cancelled }
                        buffer.append(chunk)
                        if buffer.count >= Self.writeBlockSize {
                            if let stateWriter { try stateWriter.write(buffer) } else { try handle.write(contentsOf: buffer) }
                            progress?.updateDownloadProgress(downloaded: Int64(buffer.count), filename: basename)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        if let stateWriter { try stateWriter.write(buffer) } else { try handle.write(contentsOf: buffer) }
                        progress?.updateDownloadProgress(downloaded: Int64(buffer.count), filename: basename)
                    }
                } catch {
                    dataTask.cancel()
                    try? stateWriter?.finalize()
                    try? handle.close()
                    if error is SessionError { throw error }
                    attempt = try retryOrThrow(attempt, options, error)
                    continue
                }

                try stateWriter?.finalize()
                try handle.close()

                try finalSizeMatches(partURL, expectedSize: expectedSize)
                if let validate = options.validate {
                    do {
                        try validate(partURL)
                    } catch {
                        DownloadStateStore.cleanupPartial(destination: destination)
                        attempt = try retryOrThrow(attempt, options, error)
                        continue
                    }
                }

                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: partURL, to: destination)
                try? FileManager.default.removeItem(at: stateURL)
                progress?.markFileAsDone(basename)
                return
            } catch let error as SessionError {
                if case .cancelled = error { throw error }
                attempt = try retryOrThrow(attempt, options, error)
                continue
            }
        }
    }

    private func retryOrThrow(_ attempt: Int, _ options: DownloadOptions, _ error: Error) throws -> Int {
        guard options.doRetries, attempt < maxRetries else { throw error }
        return attempt + 1
    }

    private func rangeStart(_ response: HTTPURLResponse) -> Int64? {
        guard let contentRange = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let scanner = Scanner(string: contentRange)
        _ = scanner.scanString("bytes")
        var start: Int64 = 0
        guard scanner.scanInt64(&start) else { return nil }
        return start
    }

    private func resolveExpectedSize(http: HTTPURLResponse, existingOffset: Int64, expected: Int64) -> Int64 {
        if expected > 0 { return expected }
        if http.expectedContentLength >= 0 {
            if existingOffset > 0, http.statusCode == 206 {
                return existingOffset + http.expectedContentLength
            }
            return http.expectedContentLength
        }
        return 0
    }

    private func validateExisting(_ destination: URL, options: DownloadOptions) throws {
        try finalSizeMatches(destination, expectedSize: options.expectedSize)
        try options.validate?(destination)
    }

    private func finalSizeMatches(_ url: URL, expectedSize: Int64) throws {
        guard expectedSize > 0 else { return }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int64) ?? 0
        guard size == expectedSize else { throw SessionError.sizeMismatch(expected: expectedSize, got: size) }
    }

    private func prepareState(destination: URL, partURL: URL, stateURL: URL, urlString: String, options: DownloadOptions) throws -> (DownloadState?, Int64) {
        guard options.allowResume else {
            DownloadStateStore.cleanupPartial(destination: destination)
            return (nil, 0)
        }

        guard let loaded = try? DownloadStateStore.load(from: stateURL) else {
            try? FileManager.default.removeItem(at: partURL)
            let fresh = DownloadState(
                url: urlString,
                expectedSize: options.expectedSize,
                segmentSize: DownloadStateStore.normalizedSegmentSize(options.segmentSize, expectedSize: options.expectedSize)
            )
            return (fresh, 0)
        }

        var state = loaded
        if !state.url.isEmpty, state.url != urlString {
            DownloadStateStore.cleanupPartial(destination: destination)
            let fresh = DownloadState(url: urlString, expectedSize: options.expectedSize, segmentSize: DownloadStateStore.normalizedSegmentSize(options.segmentSize, expectedSize: options.expectedSize))
            return (fresh, 0)
        }
        if options.expectedSize > 0, state.expectedSize > 0, state.expectedSize != options.expectedSize {
            DownloadStateStore.cleanupPartial(destination: destination)
            let fresh = DownloadState(url: urlString, expectedSize: options.expectedSize, segmentSize: DownloadStateStore.normalizedSegmentSize(options.segmentSize, expectedSize: options.expectedSize))
            return (fresh, 0)
        }

        guard FileManager.default.fileExists(atPath: partURL.path) else {
            try? FileManager.default.removeItem(at: stateURL)
            let fresh = DownloadState(url: urlString, expectedSize: options.expectedSize, segmentSize: DownloadStateStore.normalizedSegmentSize(options.segmentSize, expectedSize: options.expectedSize))
            return (fresh, 0)
        }

        state.url = urlString
        state.segmentSize = DownloadStateStore.normalizedSegmentSize(options.segmentSize, expectedSize: options.expectedSize)
        if options.expectedSize > 0 { state.expectedSize = options.expectedSize }

        let verifiedOffset = try DownloadStateStore.verifyPartialFile(at: partURL, state: &state)
        try DownloadStateStore.rewrite(state, to: stateURL)
        return (state, verifiedOffset)
    }
}

// MARK: - Parallel ranged downloads

enum SegmentedError: Error {
    case rangesUnsupported
}

extension SegmentedState {
    static func remove(for destination: URL) {
        try? FileManager.default.removeItem(at: url(for: destination))
        try? FileManager.default.removeItem(at: DownloadStateStore.partURL(for: destination))
    }
}

extension NUSSession {
    /// Files at least this big are fetched as several concurrent Range requests.
    static let segmentedThreshold: Int64 = 64 << 20
    /// Target bytes per segment; the count is capped by ``maxSegments``.
    static let bytesPerSegment: Int64 = 96 << 20
    static let maxSegments = 6
    static let writeBlockSize = 1 << 20

    /// Splits a large file into ranges fetched in parallel, each written straight to its offset
    /// in the `.part` file and resumable on its own. Throws `rangesUnsupported` if the server
    /// ignores Range, so the caller can fall back to one stream.
    func downloadSegmented(urlString: String, to destination: URL, options: DownloadOptions, progress: ProgressReporter?) async throws {
        let basename = destination.lastPathComponent
        let expectedSize = options.expectedSize
        let partURL = DownloadStateStore.partURL(for: destination)
        let stateURL = SegmentedState.url(for: destination)
        let fm = FileManager.default

        var state: SegmentedState
        if let data = try? Data(contentsOf: stateURL),
           let loaded = try? JSONDecoder().decode(SegmentedState.self, from: data),
           loaded.url == urlString, loaded.expectedSize == expectedSize,
           fm.fileExists(atPath: partURL.path) {
            state = loaded
        } else {
            SegmentedState.remove(for: destination)
            let count = Int(min(Int64(Self.maxSegments), max(2, (expectedSize + Self.bytesPerSegment - 1) / Self.bytesPerSegment)))
            state = SegmentedState.make(url: urlString, expectedSize: expectedSize, segments: count)
            fm.createFile(atPath: partURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: partURL)
            try handle.truncate(atOffset: UInt64(expectedSize))
            try handle.close()
            if let data = try? JSONEncoder().encode(state) { try data.write(to: stateURL, options: .atomic) }
        }

        let alreadyDone = state.done.reduce(0, +)
        progress?.setTotalDownloaded(alreadyDone, forFile: basename)
        let tracker = SegmentProgress(state: state, stateURL: stateURL)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<(state.bounds.count - 1) {
                group.addTask {
                    try await self.downloadSegment(index: index, urlString: urlString, state: state, partURL: partURL, tracker: tracker, options: options, progress: progress, basename: basename)
                }
            }
            do {
                try await group.waitForAll()
            } catch {
                group.cancelAll()
                tracker.save()
                throw error
            }
        }
        tracker.save()

        try finalSizeMatches(partURL, expectedSize: expectedSize)
        if let validate = options.validate {
            do {
                try validate(partURL)
            } catch {
                SegmentedState.remove(for: destination)
                throw error
            }
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: partURL, to: destination)
        try? fm.removeItem(at: stateURL)
        progress?.markFileAsDone(basename)
    }

    private func downloadSegment(index: Int, urlString: String, state: SegmentedState, partURL: URL, tracker: SegmentProgress, options: DownloadOptions, progress: ProgressReporter?, basename: String) async throws {
        let segmentStart = state.bounds[index]
        let segmentEnd = state.bounds[index + 1]
        guard let url = URL(string: urlString) else { throw SessionError.badResponse }

        var attempt = 1
        while true {
            let done = tracker.done(index)
            let start = segmentStart + done
            if start >= segmentEnd { return }
            if let progress, !(await progress.waitIfPaused()) { throw SessionError.cancelled }

            var request = URLRequest(url: url)
            request.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=\(start)-\(segmentEnd - 1)", forHTTPHeaderField: "Range")

            let handle = try FileHandle(forWritingTo: partURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))

            var dataTask: URLSessionDataTask?
            do {
                let (http, stream, task) = try await session.chunkedData(for: request)
                dataTask = task
                if http.statusCode == 200 {
                    task.cancel()
                    throw SegmentedError.rangesUnsupported
                }
                guard http.statusCode == 206 else { throw SessionError.httpStatus(http.statusCode, attempts: attempt) }

                var buffer = Data()
                buffer.reserveCapacity(Self.writeBlockSize)
                var position = start
                for try await chunk in stream {
                    if let progress, !(await progress.waitIfPaused()) { throw SessionError.cancelled }
                    buffer.append(chunk)
                    if buffer.count >= Self.writeBlockSize {
                        try write(&buffer, handle: handle, position: &position, limit: segmentEnd, index: index, tracker: tracker, progress: progress, basename: basename)
                    }
                }
                if !buffer.isEmpty {
                    try write(&buffer, handle: handle, position: &position, limit: segmentEnd, index: index, tracker: tracker, progress: progress, basename: basename)
                }
                tracker.save()
                if position >= segmentEnd { return }
                throw SessionError.sizeMismatch(expected: segmentEnd, got: position)
            } catch {
                dataTask?.cancel()
                tracker.save()
                if error is SegmentedError { throw error }
                if let sessionError = error as? SessionError, case .cancelled = sessionError { throw error }
                if Task.isCancelled { throw SessionError.cancelled }
                guard options.doRetries, attempt < 5 else { throw error }
                attempt += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func write(_ buffer: inout Data, handle: FileHandle, position: inout Int64, limit: Int64, index: Int, tracker: SegmentProgress, progress: ProgressReporter?, basename: String) throws {
        // Never write past the segment, even if a server sends more than the Range asked for.
        let allowed = Int(min(Int64(buffer.count), limit - position))
        guard allowed > 0 else { buffer.removeAll(keepingCapacity: true); return }
        let slice = allowed == buffer.count ? buffer : buffer.prefix(allowed)
        try handle.write(contentsOf: slice)
        position += Int64(allowed)
        tracker.record(Int64(allowed), to: index)
        progress?.updateDownloadProgress(downloaded: Int64(allowed), filename: basename)
        buffer.removeAll(keepingCapacity: true)
    }
}
