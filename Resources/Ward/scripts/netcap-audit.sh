#!/bin/bash
#
# netcap-audit.sh — "what did this machine connect to?"
# Runs tshark over the rolling captures in /var/log/netcap and reports, sorted:
#   1. unique destination IPs with hit counts
#   2. DNS queries (names the machine looked up)
#   3. TLS SNI hostnames (names in outbound TLS ClientHellos)
#
# Usage:
#   sudo bash netcap-audit.sh                         # all captures
#   sudo bash netcap-audit.sh '<tshark display filter>'
#
# Examples of the optional filter (quote it as ONE argument):
#   'frame.time >= "2026-11-02 09:00:00"'
#   'frame.time >= "2026-11-02 09:00:00" && frame.time <= "2026-11-02 12:00:00"'
#   'ip.dst == 203.0.113.5'
#
# Needs root to read the capture files (dir is 0700 root).
#
set -euo pipefail

CAPDIR="/var/log/netcap"
PREFIX="cap"
TSHARK="$(command -v tshark || echo /opt/homebrew/bin/tshark)"
FILTER="${1:-}"

if [ ! -x "$TSHARK" ]; then
  echo "ERROR: tshark not found." >&2
  exit 1
fi

# Gather the ring-buffer files, oldest first.
shopt -s nullglob
FILES=( "${CAPDIR}/${PREFIX}"_*.pcapng )
shopt -u nullglob
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "No capture files found in ${CAPDIR} (need root? still warming up?)." >&2
  exit 1
fi

if [ -n "$FILTER" ]; then
  echo "# Filter: $FILTER"
else
  echo "# Filter: (none — all retained traffic)"
fi
echo "# Files : ${#FILES[@]} capture file(s) in ${CAPDIR}"
echo

# run_fields <display-filter> <field> [<field>...]
# Streams the chosen fields across every capture file, honoring the time filter.
run_fields() {
  local base_filter="$1"; shift
  local combined="$base_filter"
  if [ -n "$FILTER" ]; then
    if [ -n "$combined" ]; then
      combined="($base_filter) && ($FILTER)"
    else
      combined="$FILTER"
    fi
  fi
  local f
  for f in "${FILES[@]}"; do
    local args=( -r "$f" -n -T fields )
    [ -n "$combined" ] && args+=( -Y "$combined" )
    local fld
    for fld in "$@"; do
      args+=( -e "$fld" )
    done
    "$TSHARK" "${args[@]}" 2>/dev/null || true
  done
}

echo "=================================================================="
echo " 1) DESTINATION IPs  (count  address)"
echo "=================================================================="
run_fields "ip.dst" ip.dst \
  | grep -v '^$' \
  | sort | uniq -c | sort -rn

echo
echo "=================================================================="
echo " 2) DNS QUERIES  (count  name)"
echo "=================================================================="
run_fields "dns.flags.response == 0" dns.qry.name \
  | tr '\t' '\n' | grep -v '^$' \
  | sort | uniq -c | sort -rn

echo
echo "=================================================================="
echo " 3) TLS SNI HOSTNAMES  (count  hostname)"
echo "=================================================================="
run_fields "tls.handshake.extensions_server_name" tls.handshake.extensions_server_name \
  | grep -v '^$' \
  | sort | uniq -c | sort -rn

echo
echo "# Tip: narrow with a time window, e.g."
echo "#   sudo bash $0 'frame.time >= \"2026-11-02 09:00:00\"'"
