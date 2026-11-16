import CryptoKit
import Foundation

/// Streams a single file's bytes out of an already-downloaded, still-encrypted `.app` content,
/// decrypting only the blocks that overlap the requested byte range. Large Wii U titles ship
/// multi-gigabyte contents, so unlike ``ContentDecryptor/decryptContent`` (used only for the
/// small FST content), this never holds more than one block in memory.
public enum ContentExtractor {
    public enum ExtractError: Error, LocalizedError {
        case unexpectedEOF
        case h0HashMismatch
        case readLengthNotBlockAligned
        case unsafePath(String)
        case invalidContentIndex
        case nestingTooDeep

        public var errorDescription: String? {
            switch self {
            case .unexpectedEOF: return "A downloaded content file ended early. Delete the title's folder and download it again."
            case .h0HashMismatch: return "Decrypted data failed its integrity check. The download may be corrupt — delete the title's folder and download it again."
            case .readLengthNotBlockAligned: return "A downloaded content file has an invalid size. Delete the title's folder and download it again."
            case .unsafePath(let name): return "The title contains an unsafe file path (\(name)); extraction stopped."
            case .invalidContentIndex: return "The title's file table points at a content that doesn't exist."
            case .nestingTooDeep: return "The title's folder structure is nested too deeply to extract."
            }
        }
    }

    /// Mirrors the upstream tool's `extractFileHash`: pulls `size` bytes starting at `fileOffset`
    /// out of a hash-tree ("hashed") content, verifying each 0xFC00 block against its H0 hash.
    static func extractFileHash(source: FileHandle, partDataOffset: UInt64, fileOffset: UInt64, size requestedSize: UInt64, destination: URL, contentID: UInt16, titleKey: [UInt8]) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let dst = try FileHandle(forWritingTo: destination)
        defer { try? dst.close() }

        let hashBlockSize = ContentDecryptor.hashBlockSize
        let blockSizeHashed = ContentDecryptor.blockSizeHashed
        let entriesPerLevel = UInt64(ContentDecryptor.hashEntriesPerLevel)

        var writeSize = hashBlockSize
        var blockNumber = (fileOffset / hashBlockSize) % entriesPerLevel
        var readOffset = fileOffset / hashBlockSize * blockSizeHashed
        var subOffset = fileOffset - (fileOffset / hashBlockSize * hashBlockSize)
        if subOffset + requestedSize > writeSize { writeSize -= subOffset }

        try source.seek(toOffset: partDataOffset + readOffset)
        let fileSize = try source.seekToEnd()
        try source.seek(toOffset: partDataOffset + readOffset)

        var size = requestedSize
        let zeroIVBase = UInt8(contentID & 0xFF)

        while size > 0 {
            if writeSize > size { writeSize = size }

            let currentPos = partDataOffset + readOffset
            guard fileSize > currentPos else { throw ExtractError.unexpectedEOF }
            var readLen = blockSizeHashed
            if readLen > fileSize - currentPos { readLen = fileSize - currentPos }
            guard readLen % 16 == 0 else { throw ExtractError.readLengthNotBlockAligned }
            guard readLen >= UInt64(ContentDecryptor.hashesSize) else { throw ExtractError.unexpectedEOF }

            guard let encrypted = try source.read(upToCount: Int(readLen)), encrypted.count == Int(readLen) else {
                throw ExtractError.unexpectedEOF
            }

            // The hash table's IV carries the content index in byte 1 (upstream: iv[1] = contentID).
            // A zero IV only corrupts the first 16 bytes, so every 16th block failed its H0 check.
            var hashesIV = [UInt8](repeating: 0, count: 16)
            hashesIV[1] = zeroIVBase
            let hashesRaw = try AESCBC.decrypt(data: [UInt8](encrypted.prefix(ContentDecryptor.hashesSize)), key: titleKey, iv: hashesIV)

            let h0Start = 20 * Int(blockNumber)
            let h0Hash = Array(hashesRaw[h0Start..<(h0Start + 20)])
            var ivBlock = Array(h0Hash.prefix(16))
            if blockNumber == 0 { ivBlock[1] ^= UInt8(contentID & 0xFF) }

            let encryptedData = encrypted.suffix(from: ContentDecryptor.hashesSize)
            var decrypted = try AESCBC.decrypt(data: [UInt8](encryptedData), key: titleKey, iv: ivBlock)
            if decrypted.count < Int(hashBlockSize) {
                decrypted.append(contentsOf: [UInt8](repeating: 0, count: Int(hashBlockSize) - decrypted.count))
            }
            var hash = [UInt8](Insecure.SHA1.hash(data: Data(decrypted.prefix(Int(hashBlockSize)))))
            if blockNumber == 0 { hash[1] ^= UInt8(contentID & 0xFF) }
            guard hash == h0Hash else { throw ExtractError.h0HashMismatch }

            let chunk = decrypted[Int(subOffset)..<Int(subOffset + writeSize)]
            try dst.write(contentsOf: Data(chunk))
            size -= writeSize

            blockNumber += 1
            if blockNumber >= entriesPerLevel { blockNumber = 0 }
            if subOffset != 0 { writeSize = hashBlockSize; subOffset = 0 }
            readOffset += blockSizeHashed
        }
    }

    /// Mirrors the upstream tool's `extractFile`: pulls `size` bytes starting at `fileOffset`
    /// out of a plain (non-hash-tree) content.
    static func extractFile(source: FileHandle, partDataOffset: UInt64, fileOffset: UInt64, size requestedSize: UInt64, destination: URL, contentID: UInt16, titleKey: [UInt8]) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let dst = try FileHandle(forWritingTo: destination)
        defer { try? dst.close() }

        let blockSize = ContentDecryptor.blockSize
        var writeSize = blockSize
        var readOffset = fileOffset / blockSize * blockSize
        var subOffset = fileOffset - (fileOffset / blockSize * blockSize)
        if subOffset + requestedSize > writeSize { writeSize -= subOffset }

        try source.seek(toOffset: partDataOffset + readOffset)
        let fileSize = try source.seekToEnd()
        try source.seek(toOffset: partDataOffset + readOffset)

        var iv = [UInt8](repeating: 0, count: 16)
        iv[1] = UInt8(contentID & 0xFF)

        var size = requestedSize
        while size > 0 {
            if writeSize > size { writeSize = size }

            let currentPos = partDataOffset + readOffset
            guard fileSize > currentPos else { throw ExtractError.unexpectedEOF }
            var readLen = blockSize
            if readLen > fileSize - currentPos { readLen = fileSize - currentPos }
            guard readLen % 16 == 0 else { throw ExtractError.readLengthNotBlockAligned }

            guard let encrypted = try source.read(upToCount: Int(readLen)), encrypted.count == Int(readLen) else {
                throw ExtractError.unexpectedEOF
            }
            let decrypted = try AESCBC.decrypt(data: [UInt8](encrypted), key: titleKey, iv: iv)
            if encrypted.count >= 16 { iv = Array(encrypted.suffix(16)) }

            try dst.write(contentsOf: Data(decrypted[Int(subOffset)..<Int(subOffset + writeSize)]))
            size -= writeSize

            if subOffset != 0 { writeSize = blockSize; subOffset = 0 }
            readOffset += blockSize
        }
    }

    /// Walks the decrypted FST for a Wii U title and extracts every file, matching each entry's
    /// content ID back to its downloaded (still-encrypted) `.app`/`.h3` pair on disk.
    public static func extractWiiUContents(sourceDir: URL, destinationDir: URL, tmd: TMDFormat.Metadata, titleKey: [UInt8]) throws {
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let fstContentPath = sourceDir.appendingPathComponent(cidString(tmd.contents[0].id) + ".app")
        let fstHandle = try FileHandle(forReadingFrom: fstContentPath)
        let fstDecrypted = try ContentDecryptor.decryptContent(encryptedFileURL: fstContentPath, titleKey: titleKey, content: tmd.contents[0], h3URL: hashedH3URL(sourceDir, tmd.contents[0]))
        try fstHandle.close()

        guard let table = try? FSTFormat.parse([UInt8](fstDecrypted)), !table.entries.isEmpty else {
            try extractRawWiiUContents(sourceDir: sourceDir, destinationDir: destinationDir, tmd: tmd, titleKey: titleKey)
            return
        }

        var entryStack = [UInt32](repeating: 0, count: ContentDecryptor.maxLevels)
        var level: UInt32 = 0
        var currentPath = destinationDir

        var i: UInt32 = 1
        while i < UInt32(table.entries.count) {
            if level > 0 {
                while level >= 1, table.entries[Int(entryStack[Int(level) - 1])].length == i {
                    level -= 1
                }
            }

            let entry = table.entries[Int(i)]
            if entry.type & 0x01 != 0 {
                entryStack[Int(level)] = i
                level += 1
                guard level < UInt32(ContentDecryptor.maxLevels) else { throw ExtractError.nestingTooDeep }

                var path = destinationDir
                for j in 0..<level {
                    let name = try table.name(at: table.entries[Int(entryStack[Int(j)])].nameOffset & 0x00FF_FFFF)
                    path = try safeJoin(base: destinationDir, current: path, name: name)
                }
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                i += 1
                continue
            }

            var path = destinationDir
            for j in 0..<level {
                let name = try table.name(at: table.entries[Int(entryStack[Int(j)])].nameOffset & 0x00FF_FFFF)
                path = try safeJoin(base: destinationDir, current: path, name: name)
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            }
            currentPath = path

            let fileName = try table.name(at: entry.nameOffset & 0x00FF_FFFF)
            let targetURL = try safeJoin(base: destinationDir, current: currentPath, name: fileName)

            var contentOffset = UInt64(entry.offset)
            if entry.flags & 0x04 == 0 { contentOffset *= UInt64(table.factor) }
            if entry.type & 0x80 != 0 { i += 1; continue }

            guard Int(entry.contentID) < tmd.contents.count else { throw ExtractError.invalidContentIndex }
            let matchingContent = tmd.contents[Int(entry.contentID)]
            let contentURL = sourceDir.appendingPathComponent(cidString(matchingContent.id) + ".app")
            let handle = try FileHandle(forReadingFrom: contentURL)
            defer { try? handle.close() }

            if matchingContent.type & 0x02 != 0 {
                try extractFileHash(source: handle, partDataOffset: 0, fileOffset: contentOffset, size: UInt64(entry.length), destination: targetURL, contentID: entry.contentID, titleKey: titleKey)
            } else {
                try extractFile(source: handle, partDataOffset: 0, fileOffset: contentOffset, size: UInt64(entry.length), destination: targetURL, contentID: entry.contentID, titleKey: titleKey)
            }
            i += 1
        }
    }

    static func extractRawWiiUContents(sourceDir: URL, destinationDir: URL, tmd: TMDFormat.Metadata, titleKey: [UInt8]) throws {
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        for content in tmd.contents {
            let contentURL = sourceDir.appendingPathComponent(cidString(content.id) + ".app")
            let handle = try FileHandle(forReadingFrom: contentURL)
            defer { try? handle.close() }
            let targetURL = destinationDir.appendingPathComponent(cidString(content.id) + ".dec.app")
            let contentIndex = bigEndianU16(content.index[0..<2])
            if content.type & 0x02 != 0 {
                try extractFileHash(source: handle, partDataOffset: 0, fileOffset: 0, size: content.size, destination: targetURL, contentID: contentIndex, titleKey: titleKey)
            } else {
                try extractFile(source: handle, partDataOffset: 0, fileOffset: 0, size: content.size, destination: targetURL, contentID: contentIndex, titleKey: titleKey)
            }
        }
    }

    /// Wii (not Wii U) contents are U8 archives directly, no FST indirection.
    public static func extractWiiContents(sourceDir: URL, destinationDir: URL, tmd: TMDFormat.Metadata, titleKey: [UInt8]) throws {
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        for content in tmd.contents {
            let contentURL = sourceDir.appendingPathComponent(cidString(content.id) + ".app")
            let decrypted = try ContentDecryptor.decryptContent(encryptedFileURL: contentURL, titleKey: titleKey, content: content, h3URL: hashedH3URL(sourceDir, content))

            var foundU8 = false
            var pos = 0
            let decBytes = [UInt8](decrypted)
            while pos < decBytes.count - 32 {
                defer { pos += 16 }
                guard decBytes.count >= pos + 4 else { break }
                let magic = bigEndianU32(decBytes[pos..<(pos + 4)])
                guard magic == U8Format.magic, (try? U8Format.parse(Array(decBytes[pos...]))) != nil else { continue }
                foundU8 = true
                let outURL = destinationDir.appendingPathComponent(cidString(content.id))
                try U8Format.extract(Array(decBytes[pos...]), to: outURL)
            }
            if !foundU8 {
                let outURL = destinationDir.appendingPathComponent(cidString(content.id) + ".dec.app")
                try decrypted.write(to: outURL)
            }
        }
    }

    private static func hashedH3URL(_ dir: URL, _ content: TMDFormat.ContentEntry) -> URL? {
        guard content.type & 0x02 != 0 else { return nil }
        return dir.appendingPathComponent(cidString(content.id) + ".h3")
    }

    private static func cidString(_ id: UInt32) -> String {
        String(format: "%08X", id)
    }

    /// Joins an FST name onto `current`, refusing anything that could escape `base`. Purely
    /// lexical: `standardizedFileURL` only strips the /private prefix from paths that already
    /// exist, so comparing a new folder against an existing base never matched and every
    /// extraction failed with unsafePath("code").
    static func safeJoin(base: URL, current: URL, name: String) throws -> URL {
        let parts = name.split(separator: "/", omittingEmptySubsequences: true)
        guard !name.isEmpty, !name.hasPrefix("/"), !parts.isEmpty,
              !parts.contains(where: { $0 == ".." || $0 == "." }),
              !name.contains("\0")
        else {
            throw ExtractError.unsafePath(name)
        }
        guard current.path == base.path || current.path.hasPrefix(base.path + "/") else {
            throw ExtractError.unsafePath(name)
        }
        return parts.reduce(current) { $0.appendingPathComponent(String($1)) }
    }
}
