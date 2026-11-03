#!/bin/bash
#
# netcap-uninstall.sh — stop and remove the netcap LaunchDaemon.
# Leaves the captured pcapng files in place (your choice to delete them).
#
# Run with:  sudo bash netcap-uninstall.sh   (Ward runs it from Spells; it also lives in Ward.app/Contents/Resources/scripts)
#
set -euo pipefail

LABEL="com.bluepeak.netcap"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
CAPDIR="/var/log/netcap"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root.  Use:  sudo bash $0" >&2
  exit 1
fi

echo "==> Stopping and unloading system/${LABEL}"
launchctl bootout system "$PLIST" 2>/dev/null || launchctl bootout "system/${LABEL}" 2>/dev/null || true

if [ -f "$PLIST" ]; then
  echo "==> Removing $PLIST"
  rm -f "$PLIST"
else
  echo "==> $PLIST already absent"
fi

if pgrep -f "/opt/homebrew/bin/dumpcap -i " >/dev/null 2>&1; then
  echo "    NOTE: a dumpcap process is still running; killing it."
  pkill -f "/opt/homebrew/bin/dumpcap -i " 2>/dev/null || true
fi

echo
echo "Daemon removed. Capture files are UNTOUCHED in ${CAPDIR}."
echo "To delete the captures too:   sudo rm -rf ${CAPDIR}"
