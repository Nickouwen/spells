import CryptoKit
import Foundation

/// Canonical hash encoding, v2. Mirrored byte-for-byte by `scripts/chain_ref.py` and `scripts/verify.py`.
///
///     pub_hash     = SHA256("hours/pub/v2" ‖ tag ‖ public fields)
///     priv_hash    = SHA256("hours/priv/v2" ‖ pub_hash ‖ blind[16] ‖ private fields)
///     content_hash = SHA256("hours/content/v2" ‖ tag ‖ pub_hash ‖ priv_hash)
///     hash         = SHA256("hours/chain/v2" ‖ I(seq) ‖ prev_hash[32] ‖ content_hash[32])
///     genesis      = SHA256("hours/genesis/v2" ‖ utf8(install_id))
///
///     tag   'S' (0x53) span, 'E' (0x45) edit
///     I(x)  8 bytes big-endian two's complement
///     T(s)  u32be(utf8 byte count) ‖ utf8 bytes
///     N(v)  0x00 | 0x01 ‖ enc(v)
///     span public:  I(start_ms) I(end_ms) T(tz_id) I(tz_offset_s) T(kind) N(T(bundle_id)) T(app_name)
///     span private: N(T(title)) N(T(url))
///     edit public:  I(created_ms) T(tz_id) T(op) I(lo_ms) I(hi_ms) N(I(target)) I(grp)
///     edit private: T(payload)
///
/// The split lets a proof bundle withhold the private fields (shipping `priv_hash` instead) while every
/// public field it shows stays bound to the chain. `blind` is 16 random bytes per row (stored in the
/// row's `blind` column, shipped only at L2), so a withheld `priv_hash` can't be brute-forced by hashing
/// guessed titles, and equal titles never give equal digests. `priv_hash` is derived, never stored.
/// The edit payload is hashed verbatim as stored.
public enum ChainCodec {
    public static let spanTag: UInt8 = 0x53, editTag: UInt8 = 0x45

    public static func genesis(installId: String) -> Data {
        var e = Encoder("hours/genesis/v2")
        e.bytes.append(contentsOf: Array(installId.utf8))
        return e.digest()
    }

    public static func spanPublic(startMs: Int64, endMs: Int64, tzId: String, tzOffsetS: Int64, kind: String,
                                  bundleId: String?, appName: String) -> Data {
        var e = Encoder("hours/pub/v2")
        e.bytes.append(spanTag)
        e.i(startMs); e.i(endMs); e.t(tzId); e.i(tzOffsetS); e.t(kind); e.nt(bundleId); e.t(appName)
        return e.digest()
    }

    public static func spanPrivate(pub: Data, blind: Data, title: String?, url: String?) -> Data {
        var e = Encoder("hours/priv/v2")
        e.bytes.append(contentsOf: pub)
        e.bytes.append(contentsOf: blind)
        e.nt(title); e.nt(url)
        return e.digest()
    }

    public static func editPublic(createdMs: Int64, tzId: String, op: String, loMs: Int64, hiMs: Int64,
                                  target: Int64?, grp: Int64) -> Data {
        var e = Encoder("hours/pub/v2")
        e.bytes.append(editTag)
        e.i(createdMs); e.t(tzId); e.t(op); e.i(loMs); e.i(hiMs)
        if let target { e.bytes.append(1); e.i(target) } else { e.bytes.append(0) }
        e.i(grp)
        return e.digest()
    }

    public static func editPrivate(pub: Data, blind: Data, payload: String) -> Data {
        var e = Encoder("hours/priv/v2")
        e.bytes.append(contentsOf: pub)
        e.bytes.append(contentsOf: blind)
        e.t(payload)
        return e.digest()
    }

    public static func content(tag: UInt8, pub: Data, priv: Data) -> Data {
        var e = Encoder("hours/content/v2")
        e.bytes.append(tag)
        e.bytes.append(contentsOf: pub)
        e.bytes.append(contentsOf: priv)
        return e.digest()
    }

    public static func spanContent(startMs: Int64, endMs: Int64, tzId: String, tzOffsetS: Int64, kind: String,
                                   bundleId: String?, appName: String, title: String?, url: String?, blind: Data) -> Data {
        let pub = spanPublic(startMs: startMs, endMs: endMs, tzId: tzId, tzOffsetS: tzOffsetS, kind: kind,
                             bundleId: bundleId, appName: appName)
        return content(tag: spanTag, pub: pub, priv: spanPrivate(pub: pub, blind: blind, title: title, url: url))
    }

    public static func editContent(createdMs: Int64, tzId: String, op: String, loMs: Int64, hiMs: Int64,
                                   target: Int64?, payload: String, grp: Int64, blind: Data) -> Data {
        let pub = editPublic(createdMs: createdMs, tzId: tzId, op: op, loMs: loMs, hiMs: hiMs, target: target, grp: grp)
        return content(tag: editTag, pub: pub, priv: editPrivate(pub: pub, blind: blind, payload: payload))
    }

    /// A fresh 16-byte blinding nonce (SystemRandomNumberGenerator: the OS CSPRNG on Apple platforms).
    public static func newBlind() -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    public static func rowHash(seq: Int64, prev: Data, content: Data) -> Data {
        var e = Encoder("hours/chain/v2")
        e.i(seq)
        e.bytes.append(contentsOf: prev)
        e.bytes.append(contentsOf: content)
        return e.digest()
    }

    private struct Encoder {
        var bytes: [UInt8]
        init(_ domain: String) { bytes = Array(domain.utf8) }
        mutating func i(_ x: Int64) { withUnsafeBytes(of: x.bigEndian) { bytes.append(contentsOf: $0) } }
        mutating func t(_ s: String) {
            let u = Array(s.utf8)
            withUnsafeBytes(of: UInt32(u.count).bigEndian) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: u)
        }
        mutating func nt(_ s: String?) {
            if let s { bytes.append(1); t(s) } else { bytes.append(0) }
        }
        func digest() -> Data { Data(SHA256.hash(data: bytes)) }
    }
}

extension Data {
    var storeHex: String { map { String(format: "%02x", $0) }.joined() }
}
