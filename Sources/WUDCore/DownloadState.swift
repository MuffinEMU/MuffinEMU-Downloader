import Foundation
import CryptoKit

/// Append-only resume journal for a single in-progress download, so a killed app or dropped
/// connection can resume from the last verified byte instead of restarting a multi-GB title.
/// Segments are hashed on write and re-verified against the `.part` file on disk before resuming,
/// so silent truncation/corruption falls back to re-downloading just the bad tail.
struct DownloadSegment: Codable {
    var offset: Int64
    var size: Int64
    var sha256: String
}

struct DownloadState: Codable {
    var url: String
    var expectedSize: Int64
    var segmentSize: Int64
    var verifiedOffset: Int64 = 0
    var lastModified: String?
    var eTag: String?
    var segments: [DownloadSegment] = []
    var partialSegment: DownloadSegment?
}

enum DownloadStateStore {
    static let journalMagic = "WUDRESUME2"
    private static let journalHeader = Data((journalMagic + "\n").utf8)

    static let defaultSegmentSize: Int64 = 1 << 20
    static let mediumSegmentSize: Int64 = 4 << 20
    static let largeSegmentSize: Int64 = 16 << 20
    static let maxSmallDownloadSize: Int64 = 64 << 20
    static let maxMediumDownloadSize: Int64 = 1 << 30

    enum StateError: Error { case invalid }

    static func partURL(for destination: URL) -> URL {
        destination.appendingPathExtension("part")
    }

    static func stateURL(for destination: URL) -> URL {
        URL(fileURLWithPath: destination.path + ".resume.json")
    }

    static func normalizedSegmentSize(_ segmentSize: Int64, expectedSize: Int64) -> Int64 {
        if segmentSize > 0 { return segmentSize }
        switch true {
        case expectedSize > 0 && expectedSize <= defaultSegmentSize: return expectedSize
        case expectedSize > 0 && expectedSize <= maxSmallDownloadSize: return defaultSegmentSize
        case expectedSize > 0 && expectedSize <= maxMediumDownloadSize: return mediumSegmentSize
        case expectedSize > 0: return largeSegmentSize
        default: return defaultSegmentSize
        }
    }

    static func hashHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func load(from url: URL) throws -> DownloadState {
        let data = try Data(contentsOf: url)
        guard data.starts(with: journalHeader) else {
            return try JSONDecoder().decode(DownloadState.self, from: data)
        }
        let body = data.dropFirst(journalHeader.count)
        var found: DownloadState?
        for line in body.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let decoded = try? JSONDecoder().decode(DownloadState.self, from: Data(line)) else { continue }
            found = decoded
        }
        guard let state = found else { throw StateError.invalid }
        return state
    }

    static func save(_ state: DownloadState, to url: URL) throws {
        try append(state, to: url, forceRewrite: false)
    }

    static func rewrite(_ state: DownloadState, to url: URL) throws {
        try append(state, to: url, forceRewrite: true)
    }

    private static func append(_ state: DownloadState, to url: URL, forceRewrite: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = try JSONEncoder().encode(state)

        let hasHeader = (try? FileHandle(forReadingFrom: url))?.readData(ofLength: journalHeader.count) == journalHeader
        if forceRewrite || !hasHeader {
            var out = journalHeader
            out.append(line)
            out.append(UInt8(ascii: "\n"))
            try out.write(to: url, options: .atomic)
            return
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
    }

    static func cleanupPartial(destination: URL) {
        try? FileManager.default.removeItem(at: partURL(for: destination))
        try? FileManager.default.removeItem(at: stateURL(for: destination))
    }

    /// Re-verifies every recorded segment's hash against the `.part` file, truncating at the
    /// first mismatch. Returns the confirmed-good byte offset to resume from.
    static func verifyPartialFile(at partURL: URL, state: inout DownloadState) throws -> Int64 {
        let handle = try FileHandle(forUpdating: partURL)
        defer { try? handle.close() }

        state.segmentSize = normalizedSegmentSize(state.segmentSize, expectedSize: state.expectedSize)
        var validOffset: Int64 = 0
        var trimmed: [DownloadSegment] = []

        for segment in state.segments {
            guard segment.offset == validOffset, segment.size > 0, segment.size <= state.segmentSize else { break }
            try handle.seek(toOffset: UInt64(segment.offset))
            guard let chunk = try handle.read(upToCount: Int(segment.size)), chunk.count == Int(segment.size) else {
                try handle.truncate(atOffset: UInt64(validOffset))
                break
            }
            guard hashHex(chunk) == segment.sha256 else {
                try handle.truncate(atOffset: UInt64(validOffset))
                break
            }
            trimmed.append(segment)
            validOffset += segment.size
        }
        state.segments = trimmed

        if let partial = state.partialSegment {
            guard partial.offset == validOffset, partial.size > 0, partial.size <= state.segmentSize else {
                state.partialSegment = nil
                state.verifiedOffset = validOffset
                return validOffset
            }
            try handle.seek(toOffset: UInt64(partial.offset))
            guard let chunk = try handle.read(upToCount: Int(partial.size)), chunk.count == Int(partial.size),
                  hashHex(chunk) == partial.sha256 else {
                try handle.truncate(atOffset: UInt64(validOffset))
                state.partialSegment = nil
                state.verifiedOffset = validOffset
                return validOffset
            }
            validOffset += partial.size
        }

        let actualSize = try handle.seekToEnd()
        if Int64(actualSize) != validOffset {
            try handle.truncate(atOffset: UInt64(validOffset))
        }
        state.verifiedOffset = validOffset
        return validOffset
    }
}

/// Buffers written bytes into segment-sized chunks and appends verified hashes to the resume
/// journal as they complete, so a crash mid-segment loses at most one partial segment.
final class ResumeStateWriter {
    private let handle: FileHandle
    private var state: DownloadState
    private let stateURL: URL
    private let segmentSize: Int64
    private var pending: Data = Data()
    private var pendingAt: Int64

    init(handle: FileHandle, state: DownloadState, stateURL: URL) throws {
        self.handle = handle
        self.state = state
        self.stateURL = stateURL
        self.segmentSize = state.segmentSize
        if let partial = state.partialSegment {
            try handle.seek(toOffset: UInt64(partial.offset))
            self.pending = try handle.read(upToCount: Int(partial.size)) ?? Data()
            self.pendingAt = partial.offset
        } else {
            self.pendingAt = state.verifiedOffset
        }
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        try record(data, finalize: false)
    }

    func finalize() throws {
        try reconcileFromFile()
        try record(Data(), finalize: true)
    }

    private func reconcileFromFile() throws {
        let size = Int64(try handle.seekToEnd())
        var recordedOffset = pending.isEmpty ? state.verifiedOffset : pendingAt + Int64(pending.count)
        guard size > recordedOffset else { return }

        while recordedOffset < size {
            let n = min(segmentSize, size - recordedOffset)
            try handle.seek(toOffset: UInt64(recordedOffset))
            let missing = try handle.read(upToCount: Int(n)) ?? Data()
            try record(missing, finalize: false)
            recordedOffset += n
        }
    }

    private func record(_ data: Data, finalize: Bool) throws {
        var remainingData = data
        while !remainingData.isEmpty {
            let room = Int(segmentSize) - pending.count
            if room <= 0 {
                try persistPending()
                continue
            }
            let take = min(room, remainingData.count)
            pending.append(remainingData.prefix(take))
            remainingData.removeFirst(take)
            if pending.count == Int(segmentSize) {
                try persistPending()
            }
        }
        if finalize, !pending.isEmpty {
            try savePartialPending()
        }
    }

    private func persistPending() throws {
        guard !pending.isEmpty else {
            state.partialSegment = nil
            return
        }
        let segment = DownloadSegment(offset: pendingAt, size: Int64(pending.count), sha256: DownloadStateStore.hashHex(pending))
        state.segments.append(segment)
        state.partialSegment = nil
        state.verifiedOffset = segment.offset + segment.size
        pending.removeAll(keepingCapacity: true)
        pendingAt = state.verifiedOffset
        try DownloadStateStore.save(state, to: stateURL)
    }

    private func savePartialPending() throws {
        let segment = DownloadSegment(offset: pendingAt, size: Int64(pending.count), sha256: DownloadStateStore.hashHex(pending))
        state.partialSegment = segment
        state.verifiedOffset = segment.offset + segment.size
        try DownloadStateStore.save(state, to: stateURL)
    }
}
