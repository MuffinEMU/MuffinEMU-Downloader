import CryptoKit
import Foundation
import CommonCrypto

/// Derives a fallback title key for titles NUS doesn't serve a signed ticket for.
/// This is the same key-scrambling scheme the Wii/Wii U scene's tools have documented for years;
/// what makes the output usable at all is the Wii U common key, which this type never holds
/// itself — it's supplied by the caller (from ``KeyStore``, i.e. something the user imported
/// from their own console/CFW dump).
public enum TitleKeyGenerator {
    private static let keygenSecret = "fd040105060b111c2d49"
    private static let defaultPassword: [UInt8] = Array("mypass".utf8)

    public enum GeneratorError: Error {
        case invalidTitleIDLength(Int)
        case invalidTitleIDHex
    }

    public static func generateKey(titleIDHex tid: String, passwordKind: TitleKeyPasswordKind = .mypass, commonKey: [UInt8]) throws -> [UInt8] {
        guard tid.count == 16 else { throw GeneratorError.invalidTitleIDLength(tid.count) }
        guard hexBytes(tid, expecting: 8) != nil else { throw GeneratorError.invalidTitleIDHex }

        let trimmed = trimLeadingZeroPairs(Array(tid.utf8))
        let h = Array((keygenSecret.utf8) + trimmed)

        var bh: [UInt8] = []
        bh.reserveCapacity(h.count / 2)
        var i = 0
        while i + 1 < h.count {
            let a = Int(h[i]) % 32 + 9
            let b = Int(h[i + 1]) % 32 + 9
            bh.append(UInt8((a % 25) * 16 + (b % 25)))
            i += 2
        }

        let md5sum = Insecure.MD5.hash(data: Data(bh))
        let password = passwordKind.password.isEmpty ? defaultPassword : Array(passwordKind.password.utf8)
        let derivedKey = pbkdf2SHA1(password: password, salt: Data(md5sum), iterations: 20, keyLength: 16)

        var iv = [UInt8](repeating: 0, count: 16)
        let tidBytes = Array(tid.utf8)
        var j = 0
        i = 0
        while j < 8 {
            let a = Int(tidBytes[i]) % 32 + 9
            let b = Int(tidBytes[i + 1]) % 32 + 9
            iv[j] = UInt8((a % 25) * 16 + (b % 25))
            i += 2
            j += 1
        }

        return try AESCBC.encrypt(data: derivedKey, key: commonKey, iv: iv)
    }

    private static func trimLeadingZeroPairs(_ data: [UInt8]) -> [UInt8] {
        var d = data
        while d.count >= 2, d[0] == UInt8(ascii: "0"), d[1] == UInt8(ascii: "0") {
            d.removeFirst(2)
        }
        return d
    }

    private static func hexBytes(_ string: String, expecting count: Int) -> [UInt8]? {
        guard string.count == count * 2 else { return nil }
        var bytes: [UInt8] = []
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func pbkdf2SHA1(password: [UInt8], salt: Data, iterations: Int32, keyLength: Int) -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: keyLength)
        let saltBytes = [UInt8](salt)
        _ = derived.withUnsafeMutableBytes { derivedPtr in
            saltBytes.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, password.count,
                    saltPtr.bindMemory(to: UInt8.self).baseAddress, saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    UInt32(iterations),
                    derivedPtr.bindMemory(to: UInt8.self).baseAddress, keyLength
                )
            }
        }
        return derived
    }
}

/// Minimal AES-128-CBC wrapper over CommonCrypto (CryptoKit doesn't expose CBC mode).
public enum AESCBC {
    public enum AESError: Error { case cryptoFailed(CCCryptorStatus) }

    public static func encrypt(data: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        try crypt(operation: CCOperation(kCCEncrypt), data: pkcs7Pad(data, blockSize: kCCBlockSizeAES128), key: key, iv: iv, padding: false)
    }

    public static func decrypt(data: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        try crypt(operation: CCOperation(kCCDecrypt), data: data, key: key, iv: iv, padding: false)
    }

    private static func crypt(operation: CCOperation, data: [UInt8], key: [UInt8], iv: [UInt8], padding: Bool) throws -> [UInt8] {
        var outLength = 0
        var outBytes = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        let options: CCOptions = padding ? CCOptions(kCCOptionPKCS7Padding) : 0

        let status = CCCrypt(
            operation,
            CCAlgorithm(kCCAlgorithmAES),
            options,
            key, key.count,
            iv,
            data, data.count,
            &outBytes, outBytes.count,
            &outLength
        )
        guard status == kCCSuccess else { throw AESError.cryptoFailed(status) }
        return Array(outBytes.prefix(outLength))
    }

    public static func pkcs7Pad(_ data: [UInt8], blockSize: Int) -> [UInt8] {
        let padding = blockSize - (data.count % blockSize)
        return data + [UInt8](repeating: UInt8(padding), count: padding)
    }
}
