import Foundation

/// RFC 3161 request building and structural response checks, by hand (no deps).
/// The CMS signature is NOT verified here — that's `openssl ts -verify` (see verify.py / README.txt).
public enum RFC3161 {
    static let sha256OID = ExportDER.oid("2.16.840.1.101.3.4.2.1")
    static let signedDataOID = ExportDER.oid("1.2.840.113549.1.7.2")
    static let tstInfoOID = ExportDER.oid("1.2.840.113549.1.9.16.1.4")

    public struct TokenInfo: Sendable, Equatable {
        /// The TimeStampToken (CMS ContentInfo) DER — what gets stored and what `openssl ts -verify -token_in` reads.
        public var token: Data
        public var imprint: Data
        /// Nonce magnitude (leading zeros stripped); nil if the token has none.
        public var nonce: Data?
        public var genTimeMs: Int64
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case rejected(status: Int)
        case malformed(String)
        case imprintMismatch
        case nonceMismatch

        public var description: String {
            switch self {
            case let .rejected(s): "TSA rejected the request (PKIStatus \(s))"
            case let .malformed(m): "malformed timestamp: \(m)"
            case .imprintMismatch: "token imprint ≠ requested digest"
            case .nonceMismatch: "token nonce ≠ request nonce"
            }
        }
    }

    /// TimeStampReq v1: SHA-256 imprint of `digest` (32 bytes), optional nonce, certReq.
    public static func request(digest: Data, nonce: Data?, certReq: Bool = true) -> Data {
        var body: [UInt8] = [0x02, 0x01, 0x01]
        body += ExportDER.sequence(ExportDER.sequence(sha256OID, ExportDER.null), ExportDER.octets(Array(digest)))
        if let nonce { body += ExportDER.unsigned(Array(nonce)) }
        if certReq { body += ExportDER.bool(true) }
        return Data(ExportDER.tlv(0x30, body))
    }

    /// Parses a TimeStampResp, requires status granted (0) / grantedWithMods (1), the requested
    /// imprint and (if given) nonce. Returns the token.
    public static func check(response: Data, digest: Data, nonce: Data?) throws -> TokenInfo {
        let info = try parseResponse(response)
        guard info.imprint == digest else { throw Failure.imprintMismatch }
        if let nonce {
            guard info.nonce == Data(nonce.drop { $0 == 0 }) else { throw Failure.nonceMismatch }
        }
        return info
    }

    public static func parseResponse(_ response: Data) throws -> TokenInfo {
        do {
            let resp = try ExportDER.parse(ArraySlice(response)).children
            guard let statusInfo = resp.first, let status = try statusInfo.children.first, status.tag == 0x02 else {
                throw Failure.malformed("no PKIStatusInfo")
            }
            guard status.intValue <= 1 else { throw Failure.rejected(status: status.intValue) }
            guard resp.count >= 2 else { throw Failure.malformed("granted but no token") }
            return try parseToken(Data(resp[1].raw))
        } catch let e as ExportDER.Malformed {
            throw Failure.malformed(e.description)
        }
    }

    /// Walks ContentInfo → SignedData → encapContentInfo → TSTInfo.
    public static func parseToken(_ token: Data) throws -> TokenInfo {
        do {
            let ci = try ExportDER.parse(ArraySlice(token)).children
            guard ci.count == 2, Array(ci[0].raw) == signedDataOID, ci[1].tag == 0xA0 else {
                throw Failure.malformed("not CMS SignedData")
            }
            let sd = try ExportDER.parse(ci[1].body).children
            guard sd.count >= 3 else { throw Failure.malformed("short SignedData") }
            let encap = try sd[2].children
            guard encap.count == 2, Array(encap[0].raw) == tstInfoOID, encap[1].tag == 0xA0 else {
                throw Failure.malformed("content is not TSTInfo")
            }
            let octets = try ExportDER.parse(encap[1].body)
            guard octets.tag == 0x04 else { throw Failure.malformed("eContent not an OCTET STRING") }
            let tst = try ExportDER.parse(octets.body).children
            // version, policy, messageImprint, serialNumber, genTime, accuracy?, ordering?, nonce?, …
            guard tst.count >= 5, tst[4].tag == 0x18 else { throw Failure.malformed("short TSTInfo") }
            let mi = try tst[2].children
            guard mi.count == 2, Array(try mi[0].children.first?.raw ?? []) == sha256OID, mi[1].tag == 0x04 else {
                throw Failure.malformed("imprint is not SHA-256")
            }
            guard let gen = generalizedTimeMs(String(decoding: tst[4].body, as: UTF8.self)) else {
                throw Failure.malformed("bad genTime")
            }
            let nonce = tst.dropFirst(5).first { $0.tag == 0x02 }.map { Data($0.magnitude) }
            return TokenInfo(token: token, imprint: Data(mi[1].body), nonce: nonce, genTimeMs: gen)
        } catch let e as ExportDER.Malformed {
            throw Failure.malformed(e.description)
        }
    }

    /// `YYYYMMDDHHMMSS[.fff…]Z` → unix ms.
    static func generalizedTimeMs(_ s: String) -> Int64? {
        guard s.hasSuffix("Z"), s.count >= 15 else { return nil }
        let d = Array(s.utf8)
        func n(_ a: Int, _ len: Int) -> Int? { Int(String(decoding: d[a..<a + len], as: UTF8.self)) }
        guard let y = n(0, 4), let mo = n(4, 2), let da = n(6, 2), let h = n(8, 2), let mi = n(10, 2), let se = n(12, 2)
        else { return nil }
        var ms = 0
        if d[14] == UInt8(ascii: ".") {
            let frac = String(decoding: d[15..<d.count - 1], as: UTF8.self)
            ms = Int((frac + "000").prefix(3)) ?? 0
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let date = cal.date(from: DateComponents(year: y, month: mo, day: da, hour: h, minute: mi, second: se))
        else { return nil }
        return Int64(date.timeIntervalSince1970) * 1000 + Int64(ms)
    }
}
