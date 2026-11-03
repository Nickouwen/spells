#!/bin/bash
# Scan the netcap ring-buffer captures for known-bad IOCs from the 2026-11-02 infostealer.
# Run: sudo bash ~/.claude/skills/netcap/netcap-ioc-check.sh
set -u
DIR=/var/log/netcap
TSHARK=/opt/homebrew/bin/tshark
FILTER='ip.addr==85.193.68.245 || ip.addr==144.217.67.186 || ip.addr==172.67.135.143 || ip.addr==104.21.26.56 || ipv6.addr==2606:4700:3036::ac43:878f || ipv6.addr==2606:4700:3033::6815:1a38 || frame contains "okaloq" || frame contains "tecnofixpc"'

files=$(ls -1 "$DIR"/cap_*.pcapng 2>/dev/null)
[ -z "$files" ] && { echo "No capture files in $DIR (is the daemon running?)"; exit 1; }
nfiles=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
first=$(printf '%s\n' "$files" | head -1)

echo "IOCs checked: 85.193.68.245 (C2), okaloq.com (+CF IPs), tecnofixpc.com (144.217.67.186)"
echo "Capture files: $nfiles"
echo -n "Window starts: "; capinfos -a "$first" 2>/dev/null | awk -F': ' '/packet time/{print $2; exit}'
echo "Scanning..."

hits=0
for f in $files; do
  out=$("$TSHARK" -r "$f" -Y "$FILTER" \
        -T fields -e frame.time -e ip.src -e ipv6.src -e ip.dst -e ipv6.dst \
        -e dns.qry.name -e tls.handshake.extensions_server_name 2>/dev/null)
  if [ -n "$out" ]; then echo "=== HIT in ${f##*/} ==="; echo "$out"; hits=$((hits+1)); fi
done

echo "------------------------------------------------------------"
if [ "$hits" -eq 0 ]; then
  echo "CLEAN: no traffic to or lookups of any known-bad IOC across the entire ring."
else
  echo "WARNING: IOC traffic found in $hits file(s) above — possible residual infection, investigate now."
fi
