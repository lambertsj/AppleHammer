#!/usr/bin/env bash
#
# SimHammer test runner.
#
# Boots an iOS Simulator, runs the MonkeyTests UI test target for a fixed
# duration under a reproducible seed, and captures the build log + result
# bundle for scripts/report.sh to summarize afterwards.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCHEME=""
DEVICE=""
DURATION=60
SEED=""
PROJECT=""
WORKSPACE=""
TEST_TARGET="SimHammerTests"
LAUNCH_ARG="--uitesting"
OUTPUT_DIR="${SIMHAMMER_OUTPUT_DIR:-$SCRIPT_DIR/../.simhammer}"

usage() {
  cat <<'EOF'
Usage: scripts/run.sh -s <scheme> -d <device> [options]

Required:
  -s <scheme>       Xcode scheme to test
  -d <device>       Simulator device name (e.g. "iPhone 15") or UDID

Options:
  -t <seconds>      Monkey run duration in seconds (default: 60)
  -e <seed>         Seed for the PRNG (default: derived from the current time
                     and printed, so every run is reproducible after the fact)
  -p <path>         Path to .xcodeproj (auto-detected if omitted)
  -w <path>         Path to .xcworkspace, takes precedence over -p
                     (auto-detected if omitted)
  -x <target>       UI test target name (default: SimHammerTests)
  -a <launch arg>   Launch argument passed to the app under test
                     (default: --uitesting)
  -o <dir>          Output directory for logs/results (default: ./.simhammer)
  -h                Show this help

Examples:
  scripts/run.sh -s MyApp -d "iPhone 15"
  scripts/run.sh -s MyApp -d "iPhone 15" -t 120 -e 424242
EOF
}

while getopts "s:d:t:e:p:w:x:a:o:h" opt; do
  case "$opt" in
    s) SCHEME="$OPTARG" ;;
    d) DEVICE="$OPTARG" ;;
    t) DURATION="$OPTARG" ;;
    e) SEED="$OPTARG" ;;
    p) PROJECT="$OPTARG" ;;
    w) WORKSPACE="$OPTARG" ;;
    x) TEST_TARGET="$OPTARG" ;;
    a) LAUNCH_ARG="$OPTARG" ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

if [[ -z "$SCHEME" || -z "$DEVICE" ]]; then
  echo "error: -s <scheme> and -d <device> are required" >&2
  usage
  exit 1
fi

# Always resolve a concrete seed up front (even if the caller didn't pass
# one) so it's printed and known before xcodebuild even starts.
if [[ -z "$SEED" ]]; then
  SEED="$(( $(date +%s) * 1000 + RANDOM ))"
fi

mkdir -p "$OUTPUT_DIR"

echo "=============================================="
echo " SimHammer run"
echo "  scheme:   $SCHEME"
echo "  device:   $DEVICE"
echo "  duration: ${DURATION}s"
echo "  seed:     $SEED"
echo "  output:   $OUTPUT_DIR"
echo "=============================================="
echo "SIMHAMMER_SEED=$SEED"

# Auto-detect a workspace or project in the current directory if neither
# was passed explicitly.
if [[ -z "$WORKSPACE" && -z "$PROJECT" ]]; then
  found_workspace="$(find . -maxdepth 2 -name '*.xcworkspace' -not -path '*/project.xcworkspace' 2>/dev/null | head -n1 || true)"
  if [[ -n "$found_workspace" ]]; then
    WORKSPACE="$found_workspace"
  else
    found_project="$(find . -maxdepth 2 -name '*.xcodeproj' 2>/dev/null | head -n1 || true)"
    PROJECT="$found_project"
  fi
fi

PROJECT_FLAGS=()
if [[ -n "$WORKSPACE" ]]; then
  PROJECT_FLAGS=(-workspace "$WORKSPACE")
elif [[ -n "$PROJECT" ]]; then
  PROJECT_FLAGS=(-project "$PROJECT")
else
  echo "error: no .xcworkspace or .xcodeproj found; pass -w or -p explicitly" >&2
  exit 1
fi

# Boot the simulator if it isn't already running.
if ! xcrun simctl list devices 2>/dev/null | grep -F "$DEVICE" | grep -q "(Booted)"; then
  echo "Booting simulator: $DEVICE"
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
  xcrun simctl bootstatus "$DEVICE" -b || true
fi

RESULT_BUNDLE="$OUTPUT_DIR/SimHammer-$SEED.xcresult"
BUILD_LOG="$OUTPUT_DIR/xcodebuild-$SEED.log"
rm -rf "$RESULT_BUNDLE"

set +e
xcodebuild test \
  "${PROJECT_FLAGS[@]}" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -only-testing:"$TEST_TARGET/MonkeyTests" \
  -resultBundlePath "$RESULT_BUNDLE" \
  TEST_RUNNER_SIMHAMMER_SEED="$SEED" \
  TEST_RUNNER_SIMHAMMER_DURATION="$DURATION" \
  TEST_RUNNER_SIMHAMMER_LOG_DIR="$OUTPUT_DIR" \
  TEST_RUNNER_SIMHAMMER_LAUNCH_ARG="$LAUNCH_ARG" \
  2>&1 | tee "$BUILD_LOG"
STATUS=${PIPESTATUS[0]}
set -e

echo "=============================================="
echo " SimHammer finished (xcodebuild exit $STATUS)"
echo "  seed:          $SEED"
echo "  build log:     $BUILD_LOG"
echo "  result bundle: $RESULT_BUNDLE"
echo "  action log:    $OUTPUT_DIR/action-log-$SEED.jsonl"
echo ""
echo "  summarize:     scripts/report.sh \"$OUTPUT_DIR\" $SEED"
echo "  reproduce:     scripts/run.sh -s \"$SCHEME\" -d \"$DEVICE\" -t $DURATION -e $SEED"
echo "=============================================="

exit "$STATUS"
