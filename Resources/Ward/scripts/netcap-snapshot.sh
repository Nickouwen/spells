#!/bin/bash
#
# netcap-snapshot.sh — one report for Ward (the Spells module): the ring's facts, then the audit
# tables (destination IPs, DNS names, TLS SNI) and the IOC scan, as tab-separated lines. One tshark
# pass per capture file; files last written before the window are skipped. Needs root to read the
# captures; writes the report to OUT and hands it to UID so the app can read it.
#
# Usage: sudo bash netcap-snapshot.sh <out-file> <uid> [tshark display filter] [since-epoch]
#
set -u
OUT="$1"; OWNER="$2"; FILTER="${3:-}"; SINCE="${4:-0}"
DIR=/var/log/netcap
TSHARK=/opt/homebrew/bin/tshark
CAPINFOS=/opt/homebrew/bin/capinfos
TOP=300
IOC='ip.addr==85.193.68.245 || ip.addr==144.217.67.186 || ip.addr==172.67.135.143 || ip.addr==104.21.26.56 || ipv6.addr==2606:4700:3036::ac43:878f || ipv6.addr==2606:4700:3033::6815:1a38 || frame contains "okaloq" || frame contains "tecnofixpc"'

tmp="$(mktemp)"
work="$(mktemp -d)"
trap 'rm -rf "$tmp" "$work"' EXIT

# Oldest first, by write time (the ring's sequence numbers keep counting, names sort the same way).
files=()
while IFS= read -r f; do files+=("$f"); done < <(ls -1tr "$DIR"/cap_*.pcapng 2>/dev/null)

{
  echo -e "files\t${#files[@]}"
  total=0
  for f in ${files[@]+"${files[@]}"}; do total=$((total + $(stat -f %z "$f"))); done
  echo -e "bytes\t$total"
  if [ "${#files[@]}" -gt 0 ]; then
    first="$("$CAPINFOS" -a -S "${files[0]}" 2>/dev/null | grep -i 'packet time' | head -1 | awk '{print $NF}')"
    last="$("$CAPINFOS" -e -S "${files[${#files[@]}-1]}" 2>/dev/null | grep -i 'packet time' | head -1 | awk '{print $NF}')"
    [ -n "$first" ] && echo -e "first\t$first"
    [ -n "$last" ] && echo -e "last\t$last"
  fi
  echo -e "window\t$FILTER"
  [ -x "$TSHARK" ] || echo -e "error\ttshark not found at $TSHARK"

  base='ip.dst || dns.flags.response == 0 || tls.handshake.extensions_server_name'
  if [ -n "$FILTER" ]; then combined="($base) && ($FILTER)"; else combined="$base"; fi
  for f in ${files[@]+"${files[@]}"}; do
    if [ "$SINCE" -gt 0 ] && [ "$(stat -f %m "$f")" -lt "$SINCE" ]; then continue; fi
    "$TSHARK" -r "$f" -n -T fields -Y "$combined" -E separator=/t \
      -e ip.dst -e dns.flags.response -e dns.qry.name -e tls.handshake.extensions_server_name 2>>"$work/err" \
      | awk -F'\t' -v w="$work" '{
          if (($2 == "0" || tolower($2) == "false") && $3 != "") { n = split($3, q, ","); for (i = 1; i <= n; i++) print q[i] >> (w "/dns") }
          else if ($4 != "") { print $4 >> (w "/sni") }
          else if ($1 != "") { print $1 >> (w "/dst") }
        }'
  done
  for t in dst dns sni; do
    echo -e "section\t$t"
    [ -f "$work/$t" ] && sort "$work/$t" | uniq -c | sort -rn | head -n "$TOP" | awk '{c=$1; $1=""; sub(/^ /,""); print c "\t" $0}'
  done
  echo -e "section\tioc"
  for f in ${files[@]+"${files[@]}"}; do
    "$TSHARK" -r "$f" -n -Y "$IOC" -T fields -E separator=/t -e frame.time -e ip.src -e ip.dst -e dns.qry.name -e tls.handshake.extensions_server_name 2>>"$work/err"
  done
  if [ -s "$work/err" ]; then sort -u "$work/err" | head -5 | sed 's/^/error\t/'; fi
} > "$tmp"

mkdir -p "$(dirname "$OUT")"
install -m 0644 -o "$OWNER" "$tmp" "$OUT"
