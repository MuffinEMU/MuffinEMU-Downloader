import XCTest
@testable import WUDCore

final class KeyStoreTests: XCTestCase {
    // Fabricated 16-byte values for test purposes only — not real Nintendo keys. Registered as
    // fingerprints so the importer treats them like the real ones.
    private let fakeWiiU = [UInt8](repeating: 0xAB, count: 16)
    private let fakeVWii = (0..<16).map { UInt8($0 * 7 & 0xFF) }

    override func setUp() {
        super.setUp()
        KeyName.testFingerprints = [
            KeyName.digest(fakeWiiU[...]): .wiiUCommon,
            KeyName.digest(fakeVWii[...]): .vWiiCommon,
        ]
    }

    override func tearDown() {
        KeyStore.shared.removeAll()
        KeyName.testFingerprints = [:]
        super.tearDown()
    }

    private func hex(_ bytes: [UInt8], separator: String = "") -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
    }

    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    func testImportNamedFormat() throws {
        let url = try write(Data("""
        # keys.txt
        commonKey = \(hex(fakeWiiU))
        someUnrelatedKey = 00112233
        """.utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try KeyStore.shared.importKeysFile(at: url), [.wiiUCommon])
        XCTAssertEqual(try KeyStore.shared.load(.wiiUCommon), fakeWiiU)
        XCTAssertFalse(KeyStore.shared.hasKey(.wiiCommon))
    }

    func testImportCemuStyleAndSpacedHex() throws {
        let url = try write(Data("""
        \(hex(fakeWiiU).lowercased()) # Wii U common key
        vWii common key: \(hex(fakeVWii, separator: " "))
        """.utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try KeyStore.shared.importKeysFile(at: url), [.wiiUCommon, .vWiiCommon])
    }

    func testImportLabelEndingInHexLetters() throws {
        // "code" ends in hex letters that would shift a naive 32-char match.
        let url = try write(Data("wii u common code \(hex(fakeWiiU))\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try KeyStore.shared.importKeysFile(at: url), [.wiiUCommon])
    }

    func testImportBinaryOTPLayout() throws {
        var otp = [UInt8](repeating: 0, count: 0x400)
        otp.replaceSubrange(0xE0..<0xF0, with: fakeWiiU)
        otp.replaceSubrange(0xD0..<0xE0, with: fakeVWii)
        let url = try write(Data(otp))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try KeyStore.shared.importKeysFile(at: url), [.wiiUCommon, .vWiiCommon])
    }

    func testImportWithNoRecognizedKeysThrows() throws {
        let url = try write(Data("commonKey = \(String(repeating: "cd", count: 16))".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try KeyStore.shared.importKeysFile(at: url))
    }

    func testLoadingMissingKeyThrows() {
        XCTAssertThrowsError(try KeyStore.shared.load(.vWiiCommon))
    }
}

extension KeyStoreTests {
    func testCemuDiscKeyFileExplainsWhatsMissing() throws {
        let url = try write(Data("""
        # this file contains keys needed for decryption of disc file system data (WUD/WUX)
        \(String(repeating: "5c", count: 16)) # example key (can be deleted)
        """.utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try KeyStore.shared.importKeysFile(at: url)) { error in
            guard case KeyStore.KeyStoreError.onlyOtherKeys(1) = error else {
                return XCTFail("expected onlyOtherKeys(1), got \(error)")
            }
        }
    }
}
