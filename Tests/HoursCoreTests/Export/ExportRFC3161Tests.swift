import Foundation
import Testing
@testable import HoursCore

@Suite struct ExportRFC3161Tests {
    static let digest = Data((0..<32).map { UInt8($0) })   // 000102…1f
    static let nonce = exportUnhex("c198d451e9b8fe27")!

    // Produced by `openssl ts -query -sha256 -digest 000102…1f [-cert] [-no_nonce]` (OpenSSL 3.6.2);
    // the nonce vector's nonce read back with `openssl ts -query -in n1.tsq -text`.
    static let opensslCertNoNonce = "30390201013031300d060960864801650304020105000420000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0101ff"
    static let opensslCertNonce = "30440201013031300d060960864801650304020105000420000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f020900c198d451e9b8fe270101ff"
    static let opensslNoCertNoNonce = "30360201013031300d060960864801650304020105000420000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

    /// `openssl ts -reply` to the nonce request above, from a throwaway local TSA (P-256, timeStamping EKU),
    /// which `openssl ts -verify -digest … -CAfile ca.pem` accepted. genTime 2026-10-06T03:33:06Z.
    static let opensslResponse = Data(base64Encoded: """
    MIIDoTADAgEAMIIDmAYJKoZIhvcNAQcCoIIDiTCCA4UCAQMxDzANBglghkgBZQMEAgEFADBzBgsqhkiG9w0BCRABBKBkBGIwYAIBAQYEKgMEATAxMA0GCWCGSAFlAwQCAQUABCAAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHwIBAhgPMjAyNjEwMDYwMzMzMDZaMAMCAQECCQDBmNRR6bj+J6CCAa8wggGrMIIBUKADAgECAhRtmfWJhZq4+dw840XEFu2JU7QiLTAKBggqhkjOPQQDAjAYMRYwFAYDVQQDDA1ob3VycyB0ZXN0IENBMCAXDTI2MTAwNjAzMzMwNloYDzIxMjYwOTEyMDMzMzA2WjAZMRcwFQYDVQQDDA5ob3VycyB0ZXN0IFRTQTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABO2nHTAkPbJwZAJkaCaRaEGC+T6TtkienPGPRqhTd9A+OpxP5xCIHkeG4yRMyyRI6FpFRMBy/eImhaAjfgUCdmSjdTBzMAkGA1UdEwQCMAAwDgYDVR0PAQH/BAQDAgeAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMB0GA1UdDgQWBBSQH4eEida6Ch0Kp2rh5M6+901lzTAfBgNVHSMEGDAWgBQBiCuFNhj6F6RTSqOMnnCzeMCjJTAKBggqhkjOPQQDAgNJADBGAiEAhUEMCNvbE3c7SllCS/q6nY7ivpio3NnhJ177t0Ual8QCIQDPBusensdpxKzyVOO+/NKUbyHb5UreVVxSanz+bULJETGCAUUwggFBAgEBMDAwGDEWMBQGA1UEAwwNaG91cnMgdGVzdCBDQQIUbZn1iYWauPncPONFxBbtiVO0Ii0wDQYJYIZIAWUDBAIBBQCggaQwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMBwGCSqGSIb3DQEJBTEPFw0yNjEwMDYwMzMzMDZaMC8GCSqGSIb3DQEJBDEiBCAOf+wE2dKc2DJ4DwIGhUpXS5GSCvyOetCnFyGNrZzjIjA3BgsqhkiG9w0BCRACLzEoMCYwJDAiBCDvvEOLuwQlkf/7rquxVrIWY4QCiUkplRa+6qGhI8+1zjAKBggqhkjOPQQDAgRIMEYCIQCuDaT243qrQCHXkxp7at6rmp6LHmvniJd1TjGVeKWgzAIhAJo36lMlb10EIp1aW4bdsg0Fa2pMAsVIk1KE2wwnLqN9
    """, options: .ignoreUnknownCharacters)!

    @Test func requestMatchesOpenSSLByteForByte() {
        #expect(exportHex(RFC3161.request(digest: Self.digest, nonce: nil)) == Self.opensslCertNoNonce)
        #expect(exportHex(RFC3161.request(digest: Self.digest, nonce: Self.nonce)) == Self.opensslCertNonce)
        #expect(exportHex(RFC3161.request(digest: Self.digest, nonce: nil, certReq: false)) == Self.opensslNoCertNoNonce)
    }

    @Test func derIntegerAndLengthEdges() {
        #expect(ExportDER.unsigned([0x00, 0x00, 0x7F]) == [0x02, 0x01, 0x7F])
        #expect(ExportDER.unsigned([0x80]) == [0x02, 0x02, 0x00, 0x80])
        #expect(ExportDER.unsigned([]) == [0x02, 0x01, 0x00])
        #expect(Array(ExportDER.octets([UInt8](repeating: 0, count: 200)).prefix(3)) == [0x04, 0x81, 0xC8])
        #expect(Array(ExportDER.octets([UInt8](repeating: 0, count: 300)).prefix(4)) == [0x04, 0x82, 0x01, 0x2C])
        #expect(ExportDER.oid("1.2.840.113549.1.7.2") == [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02])
    }

    @Test func parsesARealOpenSSLToken() throws {
        let info = try RFC3161.check(response: Self.opensslResponse, digest: Self.digest, nonce: Self.nonce)
        #expect(info.imprint == Self.digest)
        #expect(info.nonce == Self.nonce)
        #expect(info.genTimeMs == exportMs("2026-10-06 03:33") + 6_000)
        // The stored token is the ContentInfo inside the response, and parses on its own.
        #expect(try RFC3161.parseToken(info.token) == info)
        #expect(info.token.count < Self.opensslResponse.count)
    }

    @Test func rejectsWrongImprintNonceAndStatus() throws {
        var other = Self.digest; other[0] ^= 1
        #expect(throws: RFC3161.Failure.imprintMismatch) {
            try RFC3161.check(response: Self.opensslResponse, digest: other, nonce: Self.nonce)
        }
        #expect(throws: RFC3161.Failure.nonceMismatch) {
            try RFC3161.check(response: Self.opensslResponse, digest: Self.digest, nonce: Data([1, 2, 3]))
        }
        // PKIStatusInfo{ status = rejection(2) }, no token.
        #expect(throws: RFC3161.Failure.rejected(status: 2)) {
            try RFC3161.parseResponse(Data([0x30, 0x05, 0x30, 0x03, 0x02, 0x01, 0x02]))
        }
        #expect(throws: RFC3161.Failure.self) { try RFC3161.parseResponse(Data([0x30, 0x10, 0x01])) }
        #expect(throws: RFC3161.Failure.self) { try RFC3161.parseResponse(Self.opensslResponse.prefix(200)) }
    }

    @Test func nonceWithLeadingZeroComparesByMagnitude() throws {
        let nonce = Data([0x00, 0x00, 0x05, 0x06])
        let req = RFC3161.request(digest: Self.digest, nonce: nonce)
        let info = try RFC3161.check(response: try exportFakeResponse(for: req), digest: Self.digest, nonce: nonce)
        #expect(info.nonce == Data([0x05, 0x06]))
    }

    @Test func generalizedTime() {
        #expect(RFC3161.generalizedTimeMs("20261006033306Z") == exportMs("2026-10-06 03:33") + 6_000)
        #expect(RFC3161.generalizedTimeMs("20261006033306.25Z") == exportMs("2026-10-06 03:33") + 6_250)
        #expect(RFC3161.generalizedTimeMs("20261006033306") == nil)
    }
}
