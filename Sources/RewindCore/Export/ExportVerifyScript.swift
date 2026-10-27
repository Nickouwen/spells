import Foundation

/// `scripts/verify.py` verbatim, embedded so every bundle ships its own verifier (no SwiftPM resources).
/// After editing the script, paste it between the delimiters again; `ExportVerifyScriptTests` fails until you do.
enum ExportVerifyScript {
    static let source = #"""
#!/usr/bin/env python3
"""Verify an hours proof bundle without the app (Python 3 stdlib only).

usage: python3 verify.py BUNDLE_DIR [--cafile ROOTS.pem] [--openssl PATH]

Checks, in order (first failure wins, exit 1):
  1. chain   raw_spans.csv + edits.csv merged by seq: contiguous seq, prev_hash links, content digest
             recomputed from every shown field (redacted=fields: public fields + priv_hash;
             redacted=none: priv_hash recomputed from the private fields too; redacted=row: digest
             taken as given), row_hash recomputed for every row
  2. head    summary.json's chain end_seq/end_hash equal the last row
  3. anchors each anchor's head_hash equals the chain at head_seq; its token parses, is SHA-256 over
             head_hash and carries the stated genTime; with --cafile and OpenSSL 3, the TSA signature
             is checked by `openssl ts -verify` (otherwise reported as "not checked")
  4. files   every file's SHA-256 matches summary.json
Exit 0 = pass, 1 = tamper/break, 2 = usage or unreadable bundle.

Hash spec (v2), identical to the app's ChainCodec:
  pub_hash       = SHA256("hours/pub/v2" || tag || public fields)
  priv_hash      = SHA256("hours/priv/v2" || pub_hash || blind[16] || private fields)
  blind: 16 random bytes per row, shipped only at L2 (so withheld priv_hash can't be brute-forced)
  content_digest = SHA256("hours/content/v2" || tag || pub_hash || priv_hash)
  row_hash       = SHA256("hours/chain/v2" || I(seq) || prev_hash || content_digest)
  I(x) 8-byte big-endian signed; T(s) u32be(len utf8) || utf8; N(v) 0x00 | 0x01 || enc(v)
  span 'S' public:  I(start_ms) I(end_ms) T(tz_id) I(tz_offset_s) T(kind) N(T(bundle_id)) T(app_name)
  span 'S' private: N(T(title)) N(T(url))
  edit 'E' public:  I(created_ms) T(tz_id) T(op) I(lo_ms) I(hi_ms) N(I(target)) I(grp)
  edit 'E' private: T(payload)
CSV: "\\N" = NULL, "[redacted]" = withheld by the disclosure level.
"""
import csv
import datetime
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys

NULL = "\\N"
WITHHELD = "[redacted]"
FORMAT = "hours-proof/v2"
SHA256_OID = bytes.fromhex("0609608648016503040201")
SIGNED_DATA_OID = bytes.fromhex("06092a864886f70d010702")
TSTINFO_OID = bytes.fromhex("060b2a864886f70d0109100104")


def I(x): return struct.pack(">q", x)
def T(s): b = s.encode("utf-8"); return struct.pack(">I", len(b)) + b
def N(enc, v): return b"\x00" if v is None else b"\x01" + enc(v)
def sha(b): return hashlib.sha256(b).digest()
def nul(v): return None if v == NULL else v


def span_pub(r):
    return sha(b"hours/pub/v2" + b"S" + I(int(r["start_ms"])) + I(int(r["end_ms"])) + T(r["tz_id"])
               + I(int(r["tz_offset_s"])) + T(r["kind"]) + N(T, nul(r["bundle_id"])) + T(r["app_name"]))


def span_priv(pub, blind, r): return sha(b"hours/priv/v2" + pub + blind + N(T, nul(r["title"])) + N(T, nul(r["url"])))


def edit_pub(r):
    target = nul(r["target"])
    return sha(b"hours/pub/v2" + b"E" + I(int(r["created_ms"])) + T(r["tz_id"]) + T(r["op"])
               + I(int(r["lo_ms"])) + I(int(r["hi_ms"])) + N(I, None if target is None else int(target))
               + I(int(r["grp"])))


def edit_priv(pub, blind, r): return sha(b"hours/priv/v2" + pub + blind + T(r["payload"]))


def content(tag, pub, priv): return sha(b"hours/content/v2" + tag + pub + priv)


def row_hash(seq, prev, content): return sha(b"hours/chain/v2" + I(seq) + prev + content)


# --- minimal DER walk for RFC 3161 tokens -------------------------------------------------------

def der(b, i=0):
    """Returns (tag, body, raw, next_index) of the TLV at b[i]."""
    tag = b[i]
    n = b[i + 1]
    j = i + 2
    if n & 0x80:
        k = n & 0x7F
        if k == 0 or k > 4:
            raise ValueError("unsupported DER length")
        n = int.from_bytes(b[j:j + k], "big")
        j += k
    if j + n > len(b):
        raise ValueError("truncated DER")
    return tag, b[j:j + n], b[i:j + n], j + n


def children(b):
    out, i = [], 0
    while i < len(b):
        tag, body, raw, i = der(b, i)
        out.append((tag, body, raw))
    return out


def parse_token(tok):
    """ContentInfo -> SignedData -> TSTInfo. Returns (imprint bytes, genTime as datetime)."""
    ci = children(der(tok)[1])
    if len(ci) != 2 or ci[0][2] != SIGNED_DATA_OID or ci[1][0] != 0xA0:
        raise ValueError("not CMS SignedData")
    sd = children(der(ci[1][1])[1])
    encap = children(sd[2][1])
    if len(encap) != 2 or encap[0][2] != TSTINFO_OID:
        raise ValueError("content is not TSTInfo")
    tst = children(der(der(encap[1][1])[1])[1])
    mi = children(tst[2][1])
    if children(mi[0][1])[0][2] != SHA256_OID:
        raise ValueError("imprint is not SHA-256")
    if tst[4][0] != 0x18:
        raise ValueError("no genTime")
    s = tst[4][1].decode()
    gen = datetime.datetime.strptime(s[:14], "%Y%m%d%H%M%S").replace(tzinfo=datetime.timezone.utc)
    if s[14] == ".":
        gen += datetime.timedelta(milliseconds=int((s[15:-1] + "000")[:3]))
    return mi[1][1], gen


def iso_ms(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (dt.microsecond // 1000)


def find_openssl(explicit):
    for cand in [explicit, "/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl",
                 shutil.which("openssl")]:
        if not cand or not os.path.exists(cand):
            continue
        try:
            v = subprocess.run([cand, "version"], capture_output=True, text=True).stdout
        except OSError:
            continue
        if v.startswith("OpenSSL 3"):
            return cand, v.strip()
    return None, "no OpenSSL 3 found (macOS /usr/bin/openssl is LibreSSL, which can't verify these)"


def read_csv(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    opts = {}
    for k in ("--cafile", "--openssl"):
        if k in argv:
            opts[k] = argv[argv.index(k) + 1]
            args.remove(opts[k])
    if len(args) != 1:
        print(__doc__)
        return 2
    root = args[0]
    p = lambda name: os.path.join(root, name)

    def fail(msg):
        print("FAIL " + msg)
        print("RESULT    FAIL (exit 1)")
        return 1

    try:
        with open(p("summary.json"), encoding="utf-8") as f:
            summary = json.load(f)
        rows = [("raw_spans.csv", r) for r in read_csv(p("raw_spans.csv"))] + \
               [("edits.csv", r) for r in read_csv(p("edits.csv"))]
        anchors = read_csv(p("anchors.csv"))
    except (OSError, ValueError) as e:
        print(f"cannot read bundle: {e}")
        return 2
    if summary.get("format") != FORMAT:
        print(f"not a {FORMAT} bundle")
        return 2

    # 1. chain
    try:
        rows.sort(key=lambda fr: int(fr[1]["seq"]))
    except ValueError:
        return fail("chain: non-integer seq")
    hashes, prev, counts = {}, None, {"raw_spans.csv": 0, "edits.csv": 0}
    redacted = {"fields": 0, "row": 0}
    for i, (fname, r) in enumerate(rows):
        seq = int(r["seq"])
        at = f"chain: seq {seq} ({fname})"
        if i and seq != int(rows[i - 1][1]["seq"]) + 1:
            return fail(f"{at}: seq gap or duplicate after {rows[i - 1][1]['seq']}")
        try:
            rprev, digest, rhash = (bytes.fromhex(r[k]) for k in ("prev_hash", "content_digest", "row_hash"))
        except ValueError:
            return fail(f"{at}: malformed hash field")
        if prev is not None and rprev != prev:
            return fail(f"{at}: prev_hash mismatch")
        kind = r["redacted"]
        if kind in ("fields", "none"):
            # Every shown field goes into the recomputed digest; withheld private fields enter via priv_hash.
            span = fname == "raw_spans.csv"
            try:
                priv = bytes.fromhex(r["priv_hash"])
                pub = span_pub(r) if span else edit_pub(r)
            except (ValueError, KeyError):
                return fail(f"{at}: bad field values")
            if len(priv) != 32:
                return fail(f"{at}: malformed priv_hash")
            # A withheld row must not show private values: they'd be unbound (priv_hash is taken as given).
            private_cols = ("title", "url", "blind") if span else ("payload", "blind")
            if kind == "fields" and any(r.get(k) != WITHHELD for k in private_cols):
                return fail(f"{at}: withheld row carries private values")
            if kind == "none":
                try:
                    blind = bytes.fromhex(r["blind"])
                except (ValueError, KeyError):
                    blind = b""
                if len(blind) != 16:
                    return fail(f"{at}: malformed blind")
                if (span_priv(pub, blind, r) if span else edit_priv(pub, blind, r)) != priv:
                    return fail(f"{at}: priv_hash mismatch")
            if content(b"S" if span else b"E", pub, priv) != digest:
                return fail(f"{at}: content_digest mismatch")
            if kind == "fields":
                redacted["fields"] += 1
        elif kind == "row":
            # Digest only: any shown field would be unbound, so a digest-only row must show none.
            if any(v for k, v in r.items() if k not in ("seq", "redacted", "content_digest", "prev_hash", "row_hash")):
                return fail(f"{at}: digest-only row carries field values")
            redacted["row"] += 1
        else:
            return fail(f"{at}: unknown redacted value {kind!r}")
        h = row_hash(seq, rprev, digest)
        if h != rhash:
            return fail(f"{at}: row_hash mismatch")
        hashes[seq] = h
        prev = h
        counts[fname] += 1

    # 2. head
    chain = summary.get("chain", {})
    if rows:
        last = int(rows[-1][1]["seq"])
        if chain.get("end_seq") != last or chain.get("end_hash") != hashes[last].hex():
            return fail("head: summary.json chain end does not match the last row")
        first = int(rows[0][1]["seq"])
        print(f"chain     OK    {len(rows)} rows #{first}–#{last} (spans {counts['raw_spans.csv']} · "
              f"edits {counts['edits.csv']}; fields withheld {redacted['fields']} · digest-only {redacted['row']})  head {hashes[last].hex()[:12]}…")
    else:
        print("chain     OK    0 rows (no activity in period)")

    # 3. anchors
    openssl, why = find_openssl(opts.get("--openssl"))
    checked, unchecked = 0, []
    for a in anchors:
        aid, seq = a["anchor_id"], int(a["head_seq"])
        if seq not in hashes:
            return fail(f"anchor {aid}: head #{seq} outside the bundle's rows")
        if hashes[seq].hex() != a["head_hash"]:
            return fail(f"anchor {aid}: head_hash contradicts the chain at seq {seq}")
        if not a["token_file"]:
            unchecked.append(f"anchor {aid}: no token")
            continue
        try:
            with open(p(a["token_file"]), "rb") as f:
                tok = f.read()
            imprint, gen = parse_token(tok)
        except (OSError, ValueError, IndexError) as e:
            return fail(f"anchor {aid}: token unreadable ({e})")
        if imprint.hex() != a["head_hash"]:
            return fail(f"anchor {aid}: token imprint != head_hash")
        if iso_ms(gen) != a["gen_time_utc"]:
            return fail(f"anchor {aid}: genTime in token ({iso_ms(gen)}) != anchors.csv ({a['gen_time_utc']})")
        if openssl and "--cafile" in opts:
            cmd = [openssl, "ts", "-verify", "-token_in", "-in", p(a["token_file"]), "-digest", a["head_hash"],
                   "-sha256", "-CAfile", opts["--cafile"], "-attime", str(int(gen.timestamp()))]
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode != 0 or "Verification: OK" not in res.stdout:
                return fail(f"anchor {aid}: TSA signature does not verify: {(res.stdout + res.stderr).strip()[-300:]}")
            checked += 1
        else:
            unchecked.append(f"anchor {aid}")
    sig = f"signatures checked: {checked}"
    if unchecked:
        sig += f" | not checked: {len(unchecked)} ({'pass --cafile ROOTS.pem' if openssl else why})"
    print(f"anchors   OK    {len(anchors)} tokens; {sig}")
    if not anchors:
        print("WARN      no anchor covers these rows: they are chained but not timestamped")
    elif chain.get("unanchored_rows"):
        print(f"WARN      {chain['unanchored_rows']} rows after the last anchor are not timestamped")

    # 4. files
    for name, want in sorted(summary.get("files", {}).items()):
        try:
            with open(p(name), "rb") as f:
                got = hashlib.sha256(f.read()).hexdigest()
        except OSError:
            return fail(f"file {name}: missing")
        if got != want:
            return fail(f"file {name}: sha256 does not match summary.json")
    per = summary.get("period", {})
    print(f"period    {per.get('from')}..{per.get('through')}  billable {summary.get('totals', {}).get('billable_hours')} h"
          f"  disclosure {summary.get('disclosure')}")
    print(f"files     OK    {len(summary.get('files', {}))} sha256 match summary.json")
    print("RESULT    PASS (exit 0)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

"""#
}
