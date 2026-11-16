import Foundation

/// Builds the `title.cert` chain NUS downloads reference: the TMD's own two certificates,
/// plus a shared device/CA certificate blob sliced out of a `cetk` fetched live from Nintendo's
/// CCS server (a public, unauthenticated GET — no key material involved).
public enum CertificateBuilder {
    static let cetkCertStartOffset = 0x350
    static let cetkCertSize = 0x300

    private static var cachedCetkData: [UInt8]?

    public enum CertificateError: Error {
        case cetkTooShort(Int)
    }

    public static func makeCertificate(tmd: TMDFormat.Metadata, session: NUSSession) async throws -> [UInt8] {
        var cert = tmd.certificate1
        cert.append(contentsOf: tmd.certificate2)
        cert.append(contentsOf: try await defaultCertificate(session: session))
        return cert
    }

    private static func defaultCertificate(session: NUSSession) async throws -> [UInt8] {
        if let cached = cachedCetkData, hasCertData(cached) {
            return Array(cached[cetkCertStartOffset..<(cetkCertStartOffset + cetkCertSize)])
        }
        let cetkData = try await session.download(urlString: "http://ccs.cdn.c.shop.nintendowifi.net/ccs/download/000500101000400a/cetk")
        cachedCetkData = cetkData
        guard hasCertData(cetkData) else {
            throw CertificateError.cetkTooShort(cetkData.count)
        }
        return Array(cetkData[cetkCertStartOffset..<(cetkCertStartOffset + cetkCertSize)])
    }

    private static func hasCertData(_ data: [UInt8]) -> Bool {
        data.count >= cetkCertStartOffset + cetkCertSize
    }
}
