import CryptoKit
import Foundation

/// Decrypts downloaded NUS content using the title key derived from the ticket. The title key
/// itself only becomes usable once it's been unwrapped with a Wii/Wii U common key — which this
/// type receives from the caller (ultimately ``KeyStore``) and never stores or hardcodes.
public enum ContentDecryptor {
    public static let blockSize: UInt64 = 0x8000
    public static let blockSizeHashed: UInt64 = 0x10000
    public static let hashBlockSize: UInt64 = 0xFC00
    public static let hashesSize = 0x400
    public static let maxLevels = 0x10
    public static let hashEntrySize = 0x14
    public static let hashEntriesPerLevel = 0x10
    static let hashH0Start = 0x000
    static let hashH1Start = 0x140
    static let hashH2Start = 0x280
    static let hashH2End = 0x3c0
    static let contentTypeHashed: UInt16 = 0x02

    public enum DecryptError: Error {
        case h0HashMismatch
        case h1HashMismatch
        case h2HashMismatch
        case dataBlockHashInvalid
        case h3HashMismatch
        case contentHashMismatch
        case unexpectedEOF
        case fstSizeExceedsLimit
    }

    /// Unwraps the ticket's encrypted title key with the appropriate common key, selected by
    /// TMD version (Wii U titles always use the single Wii U common key; Wii titles select
    /// among up to three common keys by the ticket's key index).
    public static func decryptedTitleKey(encryptedTitleKey: [UInt8], titleID: UInt64, tmdVersion: UInt8, ticketKeyIndex: UInt8, keyStore: KeyStore) throws -> [UInt8] {
        let commonKey: [UInt8]
        if tmdVersion == TMDFormat.versionWii {
            let name: KeyName = ticketKeyIndex == 1 ? .wiiKorean : .wiiCommon
            commonKey = try keyStore.load(name)
        } else {
            commonKey = try keyStore.load(.wiiUCommon)
        }

        var iv = [UInt8](repeating: 0, count: 16)
        let idBytes = bigEndianU64(titleID)
        for i in 0..<8 { iv[i] = idBytes[i] }
        return try AESCBC.decrypt(data: encryptedTitleKey, key: commonKey, iv: iv)
    }

    /// Decrypts one content's `.app` payload fully into memory. Hash-tree ("hashed") contents
    /// carry their own H0-H3 integrity tree and are verified block by block; plain contents are
    /// verified with a single running SHA-1 against the TMD's content hash.
    public static func decryptContent(encryptedFileURL: URL, titleKey: [UInt8], content: TMDFormat.ContentEntry, h3URL: URL?) throws -> Data {
        let hasHashTree = content.type & contentTypeHashed != 0
        let handle = try FileHandle(forReadingFrom: encryptedFileURL)
        defer { try? handle.close() }
        let encryptedSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)

        if hasHashTree {
            guard let h3URL else { throw DecryptError.unexpectedEOF }
            return try decryptHashedContent(handle: handle, encryptedSize: encryptedSize, titleKey: titleKey, content: content, h3URL: h3URL)
        }
        return try decryptPlainContent(handle: handle, titleKey: titleKey, content: content)
    }

    private static func decryptHashedContent(handle: FileHandle, encryptedSize: UInt64, titleKey: [UInt8], content: TMDFormat.ContentEntry, h3URL: URL) throws -> Data {
        let h3Data = try Data(contentsOf: h3URL)
        let h3Sum = SHA1.hash(h3Data)
        guard content.hash.count >= 20, Array(h3Sum) == Array(content.hash.prefix(20)) else {
            throw DecryptError.h3HashMismatch
        }

        let chunkCount = encryptedSize / blockSizeHashed
        var out = Data()
        out.reserveCapacity(Int(encryptedSize))

        var h0Num = 0, h1Num = 0, h2Num = 0, h3Num = 0
        let zeroIV = [UInt8](repeating: 0, count: 16)

        for _ in 0..<chunkCount {
            let hashesBuffer = try handle.read(upToCount: hashesSize) ?? Data()
            guard hashesBuffer.count == hashesSize else { throw DecryptError.unexpectedEOF }
            let hashes = try AESCBC.decrypt(data: [UInt8](hashesBuffer), key: titleKey, iv: zeroIV)

            let h0Hashes = Array(hashes[hashH0Start..<hashH1Start])
            let h1Hashes = Array(hashes[hashH1Start..<hashH2Start])
            let h2Hashes = Array(hashes[hashH2Start..<hashH2End])

            let h0Hash = hashEntry(h0Hashes, index: h0Num)
            let h1Hash = hashEntry(h1Hashes, index: h1Num)
            let h2Hash = hashEntry(h2Hashes, index: h2Num)
            let h3Hash = hashEntry([UInt8](h3Data), index: h3Num)

            guard SHA1.hash(Data(h0Hashes)) == h1Hash else { throw DecryptError.h0HashMismatch }
            guard SHA1.hash(Data(h1Hashes)) == h2Hash else { throw DecryptError.h1HashMismatch }
            guard SHA1.hash(Data(h2Hashes)) == h3Hash else { throw DecryptError.h2HashMismatch }

            let encryptedData = try handle.read(upToCount: Int(hashBlockSize)) ?? Data()
            guard encryptedData.count == Int(hashBlockSize) else { throw DecryptError.unexpectedEOF }
            let iv = Array(h0Hash.prefix(16))
            let decryptedData = try AESCBC.decrypt(data: [UInt8](encryptedData), key: titleKey, iv: iv)
            guard SHA1.hash(Data(decryptedData)) == h0Hash else { throw DecryptError.dataBlockHashInvalid }

            out.append(contentsOf: hashes)
            out.append(contentsOf: decryptedData)

            (h0Num, h1Num, h2Num, h3Num) = advanceHashIndices(h0Num, h1Num, h2Num, h3Num)
        }
        return out
    }

    private static func decryptPlainContent(handle: FileHandle, titleKey: [UInt8], content: TMDFormat.ContentEntry) throws -> Data {
        // Some contents are shipped unencrypted (their SHA-1 already matches the TMD hash as-is).
        if content.hash.count >= 20 {
            try handle.seek(toOffset: 0)
            let all = try handle.readToEnd() ?? Data()
            if Array(SHA1.hash(all)) == Array(content.hash.prefix(20)) {
                return all
            }
        }

        try handle.seek(toOffset: 0)
        var iv = [UInt8](repeating: 0, count: 16)
        for i in 0..<min(2, content.index.count) { iv[i] = content.index[i] }

        var out = Data()
        var left = content.size
        var leftHash = content.size
        let readSize: UInt64 = 8 * 1024 * 1024
        var digest = Insecure.SHA1()

        while left > 0 {
            let toRead = min(readSize, left)
            let toReadHash = min(readSize, leftHash)
            let toReadAligned = ContentValidation.alignToAESBlockSize(toRead)

            guard let encrypted = try handle.read(upToCount: Int(toReadAligned)), encrypted.count == Int(toReadAligned) else {
                throw DecryptError.unexpectedEOF
            }
            let decrypted = try AESCBC.decrypt(data: [UInt8](encrypted), key: titleKey, iv: iv)
            digest.update(data: decrypted.prefix(Int(toReadHash)))
            out.append(contentsOf: decrypted.prefix(Int(toRead)))

            // CBC chains: next block's IV is this ciphertext's final 16 bytes.
            if encrypted.count >= 16 { iv = Array(encrypted.suffix(16)) }

            left -= toRead
            leftHash -= toRead
        }

        if content.hash.count >= 20 {
            let finalHash = [UInt8](digest.finalize())
            guard finalHash == Array(content.hash.prefix(20)) else { throw DecryptError.contentHashMismatch }
        }
        return out
    }

    private static func hashEntry(_ data: [UInt8], index: Int) -> [UInt8] {
        let start = index * hashEntrySize
        return Array(data[start..<(start + 20)])
    }

    private static func advanceHashIndices(_ h0: Int, _ h1: Int, _ h2: Int, _ h3: Int) -> (Int, Int, Int, Int) {
        var (h0, h1, h2, h3) = (h0, h1, h2, h3)
        h0 += 1
        if h0 >= hashEntriesPerLevel { h0 = 0; h1 += 1 }
        if h1 >= hashEntriesPerLevel { h1 = 0; h2 += 1 }
        if h2 >= hashEntriesPerLevel { h2 = 0; h3 += 1 }
        return (h0, h1, h2, h3)
    }
}
