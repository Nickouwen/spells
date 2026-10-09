#!/usr/bin/env bash
# scry-fixture.sh <dir> — a synthetic 2-channel "call" for testing the Scry pipeline without a real one:
# channel 0 = you (Sam), channel 1 = the far side (Casey as Alex, Daniel as Jordan), turns
# alternating with gaps, plus capture.json with fake call-window OCR (names + app chrome).
set -euo pipefail
DIR="${1:?usage: scry-fixture.sh <dir>}"; mkdir -p "$DIR"; T="$(mktemp -d)"
lines=(
  "1|Casey|Hey, thanks for jumping on. Can we go over the project launch?"
  "0|Sam|Sure. The mail is built, but it stays off until we have a return address."
  "1|Casey|Okay. I will send you the Example return address by Friday."
  "1|Daniel|And I can review the first batch of letters before they print."
  "0|Sam|Great. I will turn mail on once I have the address, and Jordan checks the first ten letters."
  "1|Casey|Sounds good. Let us also look at the ExamplePortal failures next Tuesday."
  "0|Sam|Will do. Thanks Alex, thanks Jordan."
)
i=0
for l in "${lines[@]}"; do
  IFS='|' read -r ch voice text <<<"$l"
  say -v "$voice" -o "$T/$i.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$T/$i.aiff" "$T/$i.wav"
  echo "$ch" > "$T/$i.ch"; i=$((i+1))
done
python3 - "$T" "$i" "$DIR" <<'PY'
import struct, sys, wave, json, datetime
t, n, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
chans, gap = [bytearray(), bytearray()], b"\x00\x00" * 16000 * 1   # 1 s of silence between turns
for k in range(n):
    ch = int(open(f"{t}/{k}.ch").read())
    with wave.open(f"{t}/{k}.wav") as w: pcm = w.readframes(w.getnframes())
    for c in (0, 1): chans[c] += pcm if c == ch else b"\x00" * len(pcm)
    for c in (0, 1): chans[c] += gap
frames = len(chans[0]) // 2
inter = bytearray()
for f in range(frames):
    inter += chans[0][2*f:2*f+2] + chans[1][2*f:2*f+2]
with wave.open(f"{out}/audio.wav", "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(inter))
end = datetime.datetime(2026, 10, 8, 14, 0, tzinfo=datetime.timezone.utc)
start = end - datetime.timedelta(seconds=frames / 16000)
json.dump({"audioFile": "audio.wav", "startedAt": start.isoformat().replace("+00:00", "Z"),
           "endedAt": end.isoformat().replace("+00:00", "Z"), "app": "us.zoom.xos",
           "screenshotText": [["Alex Client", "Mute", "Stop Video", "Jordan", "Example User (Host)", "Share Screen", "Participants", "12:04"],
                              ["Alex Client", "Jordan", "Recording", "Leave"]],
           "userNotes": "Example mail: needs return address before go-live"}, open(f"{out}/capture.json", "w"), indent=1)
print(f"fixture: {out}/audio.wav ({frames/16000:.1f} s, 2 ch) + capture.json")
PY
rm -rf "$T"
