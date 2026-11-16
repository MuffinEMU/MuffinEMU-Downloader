import Foundation

/// Streams a response body as the Data chunks URLSession receives, instead of the per-byte
/// `URLSession.AsyncBytes` iterator, which costs an async hop per byte and was the download
/// bottleneck.
final class ChunkStreamDelegate: NSObject, URLSessionDataDelegate {
    private var responseContinuation: CheckedContinuation<URLResponse, Error>?
    private let chunks: AsyncThrowingStream<Data, Error>.Continuation
    let stream: AsyncThrowingStream<Data, Error>

    override init() {
        var c: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
        chunks = c
    }

    func waitForResponse(_ task: URLSessionDataTask) async throws -> URLResponse {
        try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        responseContinuation?.resume(returning: response)
        responseContinuation = nil
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        chunks.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            responseContinuation?.resume(throwing: error)
            responseContinuation = nil
            chunks.finish(throwing: error)
        } else {
            chunks.finish()
        }
    }
}

extension URLSession {
    /// Starts `request` and returns its response plus a stream of body chunks. Cancel the task
    /// if you stop consuming early.
    func chunkedData(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>, URLSessionDataTask) {
        let delegate = ChunkStreamDelegate()
        let task = dataTask(with: request)
        task.delegate = delegate
        let response = try await withTaskCancellationHandler {
            try await delegate.waitForResponse(task)
        } onCancel: {
            task.cancel()
        }
        guard let http = response as? HTTPURLResponse else {
            task.cancel()
            throw NUSSession.SessionError.badResponse
        }
        return (http, delegate.stream, task)
    }
}

/// Per-segment progress for a parallel ranged download, persisted next to the `.part` file so
/// an interrupted download resumes each segment where it stopped.
struct SegmentedState: Codable {
    var url: String
    var expectedSize: Int64
    var bounds: [Int64]      // segment i covers bounds[i] ..< bounds[i + 1]
    var done: [Int64]        // bytes written so far in each segment

    static func url(for destination: URL) -> URL {
        URL(fileURLWithPath: destination.path + ".segments.json")
    }

    static func make(url: String, expectedSize: Int64, segments: Int) -> SegmentedState {
        let size = expectedSize / Int64(segments)
        var bounds = (0..<segments).map { Int64($0) * size }
        bounds.append(expectedSize)
        return SegmentedState(url: url, expectedSize: expectedSize, bounds: bounds, done: Array(repeating: 0, count: segments))
    }
}

/// Segment bookkeeping shared by the concurrent segment tasks. A lock rather than an actor
/// because it's updated from the synchronous write path.
final class SegmentProgress: @unchecked Sendable {
    private var state: SegmentedState
    private let stateURL: URL
    private var unsavedBytes: Int64 = 0
    private let lock = NSLock()

    init(state: SegmentedState, stateURL: URL) {
        self.state = state
        self.stateURL = stateURL
    }

    func done(_ index: Int) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return state.done[index]
    }

    func record(_ bytes: Int64, to index: Int) {
        lock.lock()
        state.done[index] += bytes
        unsavedBytes += bytes
        let shouldSave = unsavedBytes >= 8 << 20
        lock.unlock()
        // Data is written before it's counted, so saving lazily only risks re-downloading a few
        // MB after a crash, never skipping bytes.
        if shouldSave { save() }
    }

    func save() {
        lock.lock()
        unsavedBytes = 0
        let snapshot = state
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }
}
