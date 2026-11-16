import Foundation

/// Builds a "fakesigned" ticket for titles NUS doesn't hand out a real signed ticket for.
/// The template below is the same publicly-documented dummy/trucha-bug ticket payload the
/// Wii/Wii U homebrew scene has used for years (fixed placeholder signature bytes, a
/// `Root-CA00000003-XS0000000c` issuer) — it only works on consoles/emulation layers that
/// skip signature verification, and carries no Nintendo secret material itself.
public enum TicketBuilder {
    static let encryptedKeyOffset = 0x1BF
    static let encryptedKeySize = 0x10
    static let titleIDOffset = 476
    static let titleIDSize = 8
    static let titleVersionOffset = 486
    static let titleVersionSize = 2

    private static let templateHex =
        "00010004d15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed" +
        "15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed" +
        "15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed" +
        "15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed" +
        "15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed" +
        "15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed" +
        "15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed" +
        "15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed15abe11ad15ea5ed" +
        "15abe11a00000000000000000000000000000000000000000000000000000000" +
        "0000000000000000000000000000000000000000000000000000000000000000" +
        "526f6f742d434130303030303030332d58533030303030303063000000000000" +
        "0000000000000000000000000000000000000000000000000000000000000000" +
        "feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface" +
        "feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface010000cc" +
        "cccccccccccccccccccccccccccccc00000000000000000000000000aaaaaaaa" +
        "aaaaaaaa00000000000000000000000000000000000000000000000000000000" +
        "0000000000000000000000000000000000000000000000000000000000000000" +
        "0001000000000000000000000000000000000000000000000000000000000000" +
        "0000000000000000000000000000000000000000000000000000000000000000" +
        "0000000000000000000000000000000000000000000000000000000000000000" +
        "0000000000000000000000000000000000000000000000000000000000000000" +
        "0000000000010014000000ac0000001400010014000000000000002800000001" +
        "00000084000000840003000000000000ffffffffffffffffffffffffffffffff" +
        "ffffffffffffffffffffffffffffffff00000000000000000000000000000000" +
        "0000000000000000000000000000000000000000000000000000000000000000" +
        "0000000000000000000000000000000000000000000000000000000000000000" +
        "00000000000000000000000000000000"

    public enum TicketError: Error {
        case titleKeyTooShort(Int)
        case malformedTemplate
    }

    private static let templateBytes: [UInt8] = {
        var bytes: [UInt8] = []
        var index = templateHex.startIndex
        while index < templateHex.endIndex {
            let next = templateHex.index(index, offsetBy: 2)
            bytes.append(UInt8(templateHex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }()

    public static func makeTicket(titleID: UInt64, titleKey: [UInt8], titleVersion: UInt16) throws -> [UInt8] {
        guard titleKey.count >= encryptedKeySize else {
            throw TicketError.titleKeyTooShort(titleKey.count)
        }
        let requiredSize = max(
            encryptedKeyOffset + encryptedKeySize,
            titleIDOffset + titleIDSize,
            titleVersionOffset + titleVersionSize
        )
        guard templateBytes.count >= requiredSize else { throw TicketError.malformedTemplate }

        var ticket = templateBytes
        ticket.replaceSubrange(encryptedKeyOffset..<(encryptedKeyOffset + encryptedKeySize), with: titleKey.prefix(encryptedKeySize))
        ticket.replaceSubrange(titleIDOffset..<(titleIDOffset + titleIDSize), with: bigEndianU64(titleID))

        var versionBytes = [UInt8](repeating: 0, count: 2)
        versionBytes[0] = UInt8(titleVersion >> 8)
        versionBytes[1] = UInt8(titleVersion & 0xFF)
        ticket.replaceSubrange(titleVersionOffset..<(titleVersionOffset + titleVersionSize), with: versionBytes)

        return ticket
    }
}
