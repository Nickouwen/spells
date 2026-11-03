#!/bin/bash
#
# netcap-setup.sh — install an always-on rolling packet capture (forensic record
# of outbound connections) as a root LaunchDaemon. Idempotent.
#
# Run with:  sudo bash netcap-setup.sh   (Ward runs it from Spells; it also lives in Ward.app/Contents/Resources/scripts)
#
set -euo pipefail

# ---- Config -----------------------------------------------------------------
LABEL="com.bluepeak.netcap"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
CAPDIR="/var/log/netcap"
DUMPCAP="/opt/homebrew/bin/dumpcap"
IFACE="en0"              # real egress; see handoff to also add a utun (VPN) iface
SNAPLEN="256"            # IP/TCP headers + full DNS + TLS SNI; set 0 for full payload
FILESIZE_KIB="51200"     # 50 MiB per file
FILES="20"               # 20 files -> ~1 GB ring, oldest auto-deleted
PREFIX="cap"
# -----------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root.  Use:  sudo bash $0" >&2
  exit 1
fi

if [ ! -x "$DUMPCAP" ]; then
  echo "ERROR: dumpcap not found/executable at $DUMPCAP" >&2
  exit 1
fi

echo "==> Creating capture directory $CAPDIR (root:wheel 0700)"
mkdir -p "$CAPDIR"
chown root:wheel "$CAPDIR"
chmod 0700 "$CAPDIR"

echo "==> Writing LaunchDaemon $PLIST"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${DUMPCAP}</string>
        <string>-i</string>
        <string>${IFACE}</string>
        <string>-n</string>
        <string>-s</string>
        <string>${SNAPLEN}</string>
        <string>-b</string>
        <string>filesize:${FILESIZE_KIB}</string>
        <string>-b</string>
        <string>files:${FILES}</string>
        <string>-w</string>
        <string>${CAPDIR}/${PREFIX}.pcapng</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>${CAPDIR}/dumpcap.err</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST_EOF

chown root:wheel "$PLIST"
chmod 0644 "$PLIST"

echo "==> (Re)loading the daemon"
# bootout first so a re-run picks up any edits; ignore error if not loaded.
launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
launchctl enable "system/${LABEL}" 2>/dev/null || true

echo
echo "==> Verification"
sleep 2
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  echo "    service loaded: system/${LABEL}"
  launchctl print "system/${LABEL}" 2>/dev/null | grep -E 'state|pid' | head -n 2 || true
else
  echo "    WARNING: service not found in launchctl." >&2
fi

if pgrep -f "${DUMPCAP} -i ${IFACE}" >/dev/null 2>&1; then
  echo "    dumpcap process: RUNNING (pid $(pgrep -f "${DUMPCAP} -i ${IFACE}" | head -n1))"
else
  echo "    WARNING: dumpcap process not detected yet — check ${CAPDIR}/dumpcap.err" >&2
fi

echo
echo "==> Waiting up to 30s for the first capture file to appear..."
first=""
for _ in $(seq 1 15); do
  first="$(ls -1t "${CAPDIR}/${PREFIX}"_*.pcapng 2>/dev/null | head -n1 || true)"
  [ -n "$first" ] && break
  sleep 2
done

if [ -n "$first" ]; then
  echo "    first file: $first"
  capinfos "$first" 2>/dev/null || echo "    (capinfos not run)"
else
  echo "    No capture file yet (no traffic, or dumpcap failed)."
  echo "    Inspect: sudo cat ${CAPDIR}/dumpcap.err"
fi

echo
echo "Done. Ring buffer: ${FILES} x ${FILESIZE_KIB} KiB (~1 GB) on ${IFACE}, snaplen ${SNAPLEN}."
echo "Captures (root-only): ${CAPDIR}"
