#!/usr/bin/env bash
#
# AppleHammer report.
#
# Summarizes a run's action log, crash report (if any), and build log into a
# concise human-readable report: seed, duration, action count, crash point
# (if any), the last several actions before the crash, and a stack-trace
# snippet pulled from the build log.
set -euo pipefail

OUTPUT_DIR="${1:-.applehammer}"
SEED="${2:-}"

if [[ -z "$SEED" ]]; then
  latest_action_log="$(ls -t "$OUTPUT_DIR"/action-log-*.jsonl 2>/dev/null | head -n1 || true)"
  if [[ -z "$latest_action_log" ]]; then
    echo "error: no action logs found in $OUTPUT_DIR" >&2
    echo "usage: scripts/report.sh <output-dir> [seed]" >&2
    exit 1
  fi
  SEED="$(basename "$latest_action_log" | sed -E 's/action-log-([0-9]+)\.jsonl/\1/')"
fi

ACTION_LOG="$OUTPUT_DIR/action-log-$SEED.jsonl"
CRASH_REPORT="$OUTPUT_DIR/crash-report-$SEED.json"
SUMMARY_FILE="$OUTPUT_DIR/summary-$SEED.json"
BUILD_LOG="$OUTPUT_DIR/xcodebuild-$SEED.log"

echo "=============================================="
echo " AppleHammer report -- seed $SEED"
echo "=============================================="

if [[ -f "$ACTION_LOG" ]]; then
  ACTION_COUNT=$(wc -l < "$ACTION_LOG" | tr -d ' ')
  echo "actions logged: $ACTION_COUNT"
else
  echo "actions logged: (no action log found at $ACTION_LOG)"
fi

if [[ -f "$SUMMARY_FILE" ]] && command -v python3 >/dev/null 2>&1; then
  python3 - "$SUMMARY_FILE" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(f"completed:      {data.get('completed', '?')}")
print(f"duration (req): {data.get('durationRequested', '?')}s")
PYEOF
elif [[ -f "$SUMMARY_FILE" ]]; then
  echo "summary:"
  cat "$SUMMARY_FILE"
fi

if [[ -f "$CRASH_REPORT" ]]; then
  echo ""
  echo "!! CRASH / HANG DETECTED !!"
  echo "crash report: $CRASH_REPORT"
  echo ""
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$CRASH_REPORT" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(f"reason:               {data.get('reason', '?')}")
print(f"detected at:          {data.get('detectedAt', '?')}")
print(f"actions before crash: {data.get('actionCount', '?')}")
print()
actions = data.get("lastActions", [])
print(f"last {min(len(actions), 10)} actions before crash:")
for a in actions[-10:]:
    kind = a.get("type", "?")
    x, y = a.get("x", "?"), a.get("y", "?")
    extra = ""
    if kind == "swipe":
        extra = f" -> ({a.get('x2', '?')}, {a.get('y2', '?')})"
    elif kind == "longPress":
        extra = f" for {a.get('durationSeconds', '?')}s"
    print(f"  [{a.get('index', '?')}] {kind} at ({x}, {y}){extra}  {a.get('timestamp', '')}")
PYEOF
  else
    echo "(python3 not found; printing raw JSON)"
    cat "$CRASH_REPORT"
  fi
else
  echo ""
  echo "no crash report found -- run completed without a detected crash/hang."
fi

if [[ -f "$BUILD_LOG" ]]; then
  echo ""
  echo "stack trace / crash snippet from build log (if any):"
  if grep -n -A 20 -E "Fatal error|EXC_BAD_ACCESS|Terminating app due to uncaught exception|Crashed:|\*\*\* Terminating app|Thread [0-9]+ Crashed" "$BUILD_LOG" 2>/dev/null | head -n 60; then
    :
  else
    echo "  (none found in build log; check the .xcresult bundle in a Simulator crash log via 'xcrun simctl diagnose' or Xcode's Report Navigator)"
  fi
fi

echo "=============================================="
echo "reproduce with: scripts/run.sh -s <scheme> -d <device> -e $SEED"
echo "=============================================="
