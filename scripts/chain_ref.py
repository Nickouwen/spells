#!/usr/bin/env python3
"""Independent stdlib reference of the hours chain hash encoding (v2).

pub_hash     = SHA256("hours/pub/v2" || tag || public fields)
priv_hash    = SHA256("hours/priv/v2" || pub_hash || blind[16] || private fields)
blind        = 16 random bytes per row (fixed in the vector below)
content_hash = SHA256("hours/content/v2" || tag || pub_hash || priv_hash)
hash         = SHA256("hours/chain/v2" || I(seq) || prev_hash || content_hash)
genesis      = SHA256("hours/genesis/v2" || utf8(install_id))

I(x) 8-byte big-endian signed; T(s) u32be(len utf8) || utf8; N(v) 0x00 | 0x01 || enc(v)
span 'S' public:  I(start_ms) I(end_ms) T(tz_id) I(tz_offset_s) T(kind) N(T(bundle_id)) T(app_name)
span 'S' private: N(T(title)) N(T(url))
edit 'E' public:  I(created_ms) T(tz_id) T(op) I(lo_ms) I(hi_ms) N(I(target)) I(grp)
edit 'E' private: T(payload)

  --vector    print the golden vector as JSON (the Swift test compares against it)
  --selftest  recompute the vector and check it against the pinned hashes below
"""
import hashlib
import json
import struct
import sys


def I(x): return struct.pack(">q", x)
def T(s): b = s.encode("utf-8"); return struct.pack(">I", len(b)) + b
def N(enc, v): return b"\x00" if v is None else b"\x01" + enc(v)
def sha(b): return hashlib.sha256(b).digest()


def genesis(install_id): return sha(b"hours/genesis/v2" + install_id.encode("utf-8"))


def span_pub(r):
    return sha(b"hours/pub/v2" + b"S" + I(r["start_ms"]) + I(r["end_ms"]) + T(r["tz_id"])
               + I(r["tz_offset_s"]) + T(r["kind"]) + N(T, r["bundle_id"]) + T(r["app_name"]))


def span_priv(pub, r): return sha(b"hours/priv/v2" + pub + bytes.fromhex(r["blind"]) + N(T, r["title"]) + N(T, r["url"]))


def edit_pub(r):
    return sha(b"hours/pub/v2" + b"E" + I(r["created_ms"]) + T(r["tz_id"]) + T(r["op"])
               + I(r["lo_ms"]) + I(r["hi_ms"]) + N(I, r["target"]) + I(r["grp"]))


def edit_priv(pub, r): return sha(b"hours/priv/v2" + pub + bytes.fromhex(r["blind"]) + T(r["payload"]))


def content(tag, pub, priv): return sha(b"hours/content/v2" + tag + pub + priv)


def pub_priv(r):
    """(pub_hash, priv_hash, content_hash) of a full row."""
    pub = span_pub(r) if r["t"] == "S" else edit_pub(r)
    priv = span_priv(pub, r) if r["t"] == "S" else edit_priv(pub, r)
    return pub, priv, content(r["t"].encode(), pub, priv)


def row_hash(seq, prev, content): return sha(b"hours/chain/v2" + I(seq) + prev + content)


INSTALL_ID = "00000000-0000-4000-8000-000000000000"
ROWS = [
    {"t": "S", "seq": 1, "start_ms": 1772944200000, "end_ms": 1772944260000, "tz_id": "America/New_York",
     "tz_offset_s": -18000, "kind": "active", "bundle_id": "com.apple.dt.Xcode", "app_name": "Xcode",
     "title": "Store.swift — hours ✓", "url": None, "blind": "000102030405060708090a0b0c0d0e0f"},
    {"t": "S", "seq": 2, "start_ms": 1772944260000, "end_ms": 1772944320000, "tz_id": "Europe/Amsterdam",
     "tz_offset_s": 3600, "kind": "idle", "bundle_id": None, "app_name": "Safari", "title": None,
     "url": "https://example.com/a", "blind": "101112131415161718191a1b1c1d1e1f"},
    {"t": "E", "seq": 3, "created_ms": 1772944400000, "tz_id": "America/New_York", "op": "assign",
     "lo_ms": 1772944200000, "hi_ms": 1772944320000, "target": None, "payload": '{"category_id":5}', "grp": 3,
     "blind": "202122232425262728292a2b2c2d2e2f"},
    {"t": "E", "seq": 4, "created_ms": 1772944500000, "tz_id": "America/New_York", "op": "note",
     "lo_ms": 1772944200000, "hi_ms": 1772944320000, "target": 3, "payload": '{"text":"client call"}', "grp": 4,
     "blind": "303132333435363738393a3b3c3d3e3f"},
]

# Pinned at creation; any change to the encoding must bump the domain strings instead.
PINNED = {
    "genesis": "a332ef1cf7cba74977129b36364744d46aeb4740da62a0170de019a042cc9efa",
    "pub": [
        "36201ae3bf5f369052e781c85d25c4e66fa3451e84ba539b2580d9435d009f94",
        "29d43daa53b924810f41e185be3e32bc9f490bd06d0b35822313fcfcd7c5e73a",
        "e3833d19e13d1ea4f9f5a3648178893cb60a64b7aff51f94eb52883407d51a73",
        "0c604b9d4cf9610f892e0ab5df1bbe578999180e7bf50eeb8a8e86822a62c21d",
    ],
    "priv": [
        "5c467d4d4b50fc8cf655d3c053eacb38c0d8d5788fab3a5902e67d486900888b",
        "595e6d3e4204fc8d22714038ada971b0a3c9aacececaa910f5c088c886dd47ae",
        "8f23e16adbacef0c9a97ffa3ef953366bbd36330d1d1e9c23f7a804f45d8d847",
        "09f22b624301314afcdca2ad986df865d4fccaf3aedd309be8b66f91b456f8af",
    ],
    "content": [
        "7bb235b1068286d7139193a8fe13c648a6380094e7aa35f8ecedbff63836e93a",
        "a27e16fa1b78693ecad93222221cc00e42a9c396577246879bc58efd8d540897",
        "a99a57abf99e17ff45d83284e99372a84a9e3de2a212a4d644e63277a3165f98",
        "241dd57495af270acb9a987f561bbf7e16339afbb2d7f2dce4b878b42a40ef7b",
    ],
    "hash": [
        "6a17e1292d92f6bbd5c02317effe811f0922b4ad53094ab97f717fa8378c44d2",
        "1a07147fd7b5f5471721240553e0f49ccbb5fb65dec7e4a2c122d3cbaf114f43",
        "4a36797d87885458afec1d741a8643537ea1ce6eaed2a89409405ffb584dda11",
        "161cc362a25116a3a1da66981c459fbf222bd63da15f6e9911751326a7c411c5",
    ],
}


def vector():
    prev = genesis(INSTALL_ID)
    out = {"genesis": prev.hex(), "pub": [], "priv": [], "content": [], "hash": []}
    for r in ROWS:
        pub, priv, c = pub_priv(r)
        prev = row_hash(r["seq"], prev, c)
        out["pub"].append(pub.hex())
        out["priv"].append(priv.hex())
        out["content"].append(c.hex())
        out["hash"].append(prev.hex())
    return out


def main(argv):
    if "--vector" in argv:
        print(json.dumps(vector()))
        return 0
    if "--selftest" in argv:
        v = vector()
        if v != PINNED:
            print("FAIL: vector differs from pinned hashes")
            print(json.dumps(v, indent=1))
            return 1
        print(f"OK: {len(ROWS)} rows, head {v['hash'][-1][:16]}")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
