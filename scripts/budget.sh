#!/usr/bin/env bash
# budget.sh <hours> [pid] — resource-budget gate for the tracker.
# Samples physical footprint + CPU (proc_pid_rusage via footprint.swift) every BUDGET_INTERVAL_S (60)
# for <hours> into <logs>/budget-<timestamp>.csv. Exits 1 if max footprint > BUDGET_MAX_MIB (20),
# avg CPU > BUDGET_MAX_CPU_PCT (0.5), or the process died/restarted. RSS is logged, not gated.
# No pid → follows `pgrep -x HoursSpell` (a new pid = restart = fail).
# Workday run: nohup scripts/budget.sh 8 &
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOURS_ARG="${1:?usage: budget.sh <hours> [pid]}"
FIXED_PID="${2:-}"
INTERVAL="${BUDGET_INTERVAL_S:-60}"
MAX_MIB="${BUDGET_MAX_MIB:-20}"
MAX_CPU="${BUDGET_MAX_CPU_PCT:-0.5}"

TOOL="$ROOT/.build/budget/footprint"
if [[ ! -x "$TOOL" || "$ROOT/scripts/footprint.swift" -nt "$TOOL" ]]; then
  mkdir -p "$(dirname "$TOOL")"
  swiftc -O "$ROOT/scripts/footprint.swift" -o "$TOOL"
fi

if [[ -n "${SPELLS_HOME:-}" ]]; then LOGDIR="$SPELLS_HOME/logs"; else LOGDIR="$HOME/Library/Logs/Spells"; fi
mkdir -p "$LOGDIR"
CSV="$LOGDIR/budget-$(date +%Y-%m-%dT%H%M%S).csv"
echo "ts,pid,footprint_bytes,rss_bytes,cpu_ns,pkg_idle_wkups,interrupt_wkups,event" > "$CSV"

find_pid() { if [[ -n "$FIXED_PID" ]]; then echo "$FIXED_PID"; else pgrep -x HoursSpell | head -1 || true; fi; }
PID="$(find_pid)"
[[ -n "$PID" ]] || { echo "budget: no HoursSpell running; pass a pid" >&2; exit 2; }

END=$(( $(date +%s) + $(awk -v h="$HOURS_ARG" 'BEGIN { printf "%d", h * 3600 }') ))
N=0 MAX_FP=0 FAIL=""
W0="" C0="" W1="" C1=""

# One CSV row. Returns 1 (and sets FAIL) if the process is gone or was replaced.
sample() {
  local ts now_pid out rss
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  now_pid="$(find_pid)"
  if [[ "$now_pid" != "$PID" ]] || ! out="$("$TOOL" "$PID" 2>/dev/null)"; then
    local event=died; [[ -n "$now_pid" && "$now_pid" != "$PID" ]] && event="restart:$now_pid"
    echo "$ts,$PID,,,,,,$event" >> "$CSV"
    FAIL="process $PID $event"
    return 1
  fi
  read -r w fp cpu idle intr <<< "$out"
  rss=$(( $(ps -o rss= -p "$PID" 2>/dev/null || echo 0) * 1024 ))
  echo "$ts,$PID,$fp,$rss,$cpu,$idle,$intr," >> "$CSV"
  [[ -z "$W0" ]] && { W0=$w; C0=$cpu; }
  W1=$w C1=$cpu N=$((N + 1))
  (( fp > MAX_FP )) && MAX_FP=$fp
  return 0
}

while sample; do
  now=$(date +%s)
  (( now >= END )) && break
  left=$(( END - now ))
  sleep $(( left < INTERVAL ? left : INTERVAL ))
done

if (( N < 2 )); then
  echo "budget: FAIL — only $N sample(s)${FAIL:+ ($FAIL)}; csv: $CSV" >&2
  exit 1
fi
read -r verdict summary <<< "$(awk -v fp="$MAX_FP" -v dc=$((C1 - C0)) -v dw=$((W1 - W0)) \
    -v max_mib="$MAX_MIB" -v max_cpu="$MAX_CPU" -v fail="$FAIL" 'BEGIN {
  mib = fp / 1048576; cpu = dc / dw * 100
  ok = (mib <= max_mib && cpu <= max_cpu && fail == "")
  printf "%s max_footprint=%.2fMiB(limit %s) avg_cpu=%.3f%%(limit %s) wall=%ds\n", ok ? "PASS" : "FAIL", mib, max_mib, cpu, max_cpu, dw / 1e9
}')"
echo "budget: $verdict pid=$PID samples=$N $summary${FAIL:+ $FAIL} csv=$CSV"
[[ "$verdict" == PASS ]]
