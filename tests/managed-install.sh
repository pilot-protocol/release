#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pilot-managed-install-test.XXXXXX")
FIXTURE="$WORK/fixture"
FAKEBIN="$WORK/fakebin"
HOME_DIR="$WORK/home"
mkdir -p "$FIXTURE/archive" "$FAKEBIN" "$HOME_DIR"

cat > "$FIXTURE/archive/daemon" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$FIXTURE/archive/pilotctl" <<'SH'
#!/bin/sh
case "$*" in
  *"enterprise adopt"*)
    if [ -z "${PILOT_ENROLLMENT_TOKEN:-}" ]; then
      echo 'PILOT_ENROLLMENT_TOKEN is empty or invalid' >&2
      exit 1
    fi
    [ "$PILOT_ENROLLMENT_TOKEN" = 'test_one_time_token' ] || exit 91
    mkdir -p "$HOME/.pilot/managed"
    printf '%s\n' '{"mode":"managed","connector_version":"pilot-core-managed-test"}' > "$HOME/.pilot/managed/enterprise-control.json"
    printf '%s\n' '{"ok":true,"data":{"control_path":"managed"}}'
    ;;
  "daemon status --check")
    [ -f "$HOME/.pilot/.daemon-running" ]
    ;;
  "daemon stop")
    rm -f "$HOME/.pilot/.daemon-running"
    ;;
  daemon\ start*)
    : > "$HOME/.pilot/.daemon-running"
    ;;
  version)
    echo managed-runtime-v9.9.9
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod 755 "$FIXTURE/archive/daemon" "$FIXTURE/archive/pilotctl"
COPYFILE_DISABLE=1 tar -czf "$FIXTURE/pilot-linux-amd64.tar.gz" -C "$FIXTURE/archive" .
SHA=$(shasum -a 256 "$FIXTURE/pilot-linux-amd64.tar.gz" | awk '{print $1}')
printf '%s  %s\n' "$SHA" pilot-linux-amd64.tar.gz > "$FIXTURE/checksums.txt"
# Keep this intentionally compact and put another platform after linux-amd64.
# The hosted authority emits compact JSON; the former line-range parser then
# selected the final hash on the line instead of the requested platform.
printf '%s\n' "{\"schema_version\":1,\"latest_stable\":\"managed-runtime-v9.9.9\",\"platforms\":{\"darwin-amd64\":{\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},\"darwin-arm64\":{\"sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"},\"linux-amd64\":{\"sha256\":\"$SHA\"},\"linux-arm64\":{\"sha256\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"}}}" > "$FIXTURE/manifest.json"
cat > "$FIXTURE/stable-manifest.json" <<JSON
{
  "schema_version": 1,
  "latest_stable": "v9.9.9",
  "channels": {"stable": "v9.9.9", "beta": "v9.9.9"},
  "platforms": {
    "linux-amd64": {
      "sha256": "$SHA"
    }
  }
}
JSON

cat > "$FAKEBIN/uname" <<'SH'
#!/bin/sh
case "${1:-}" in
  -s) echo Linux ;;
  -m) echo x86_64 ;;
  *) echo Linux ;;
esac
SH
cat > "$FAKEBIN/curl" <<'SH'
#!/bin/sh
if [ -n "${PILOT_ENROLLMENT_TOKEN+x}" ]; then
  echo 'enrollment token leaked to curl' >&2
  exit 90
fi
: "${PILOT_TEST_FIXTURE:?}"
url=""
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"; shift 2 ;;
    --max-time|-w)
      shift 2 ;;
    http://*|https://*)
      url="$1"; shift ;;
    *)
      shift ;;
  esac
done
[ -n "$output" ] || exit 89
case "$url" in
  */.well-known/pilot-managed-runtime.json) source="$PILOT_TEST_FIXTURE/manifest.json" ;;
  */.well-known/latest.json) source="$PILOT_TEST_FIXTURE/stable-manifest.json" ;;
  */pilot-linux-amd64.tar.gz) source="$PILOT_TEST_FIXTURE/pilot-linux-amd64.tar.gz" ;;
  */checksums.txt) source="$PILOT_TEST_FIXTURE/checksums.txt" ;;
  *) echo "unexpected curl URL: $url" >&2; exit 88 ;;
esac
cp "$source" "$output"
SH
chmod 755 "$FAKEBIN/uname" "$FAKEBIN/curl"

LOG="$WORK/install.log"
PATH="$FAKEBIN:$PATH" \
HOME="$HOME_DIR" \
PILOT_TEST_FIXTURE="$FIXTURE" \
PILOT_ENROLLMENT_TOKEN=test_one_time_token \
sh "$ROOT/install.sh" --managed-url https://management.example > "$LOG" 2>&1

test -x "$HOME_DIR/.pilot/bin/pilotctl"
test -x "$HOME_DIR/.pilot/bin/pilot-daemon"
test -f "$HOME_DIR/.pilot/managed/enterprise-control.json"
test -f "$HOME_DIR/.pilot/.daemon-running"
grep -F 'Managed Pilot node ready:' "$LOG" >/dev/null
grep -F 'MCP:        not installed (optional, separate product)' "$LOG" >/dev/null
if grep -F 'test_one_time_token' "$LOG" >/dev/null; then
  echo 'enrollment token leaked to installer output' >&2
  exit 1
fi

MISSING_HOME="$WORK/missing-home"
mkdir -p "$MISSING_HOME"
if PATH="$FAKEBIN:$PATH" HOME="$MISSING_HOME" PILOT_TEST_FIXTURE="$FIXTURE" \
  sh "$ROOT/install.sh" --managed-url https://management.example > "$WORK/missing.log" 2>&1; then
  echo 'first managed install succeeded without a token' >&2
  exit 1
fi
grep -F 'PILOT_ENROLLMENT_TOKEN is required' "$WORK/missing.log" >/dev/null
test ! -e "$MISSING_HOME/.pilot"

if PATH="$FAKEBIN:$PATH" HOME="$HOME_DIR" PILOT_TEST_FIXTURE="$FIXTURE" \
  PILOT_ENROLLMENT_TOKEN=second_token \
  sh "$ROOT/install.sh" --managed-url https://management.example > "$WORK/replay.log" 2>&1; then
  echo 'already-managed node accepted another token' >&2
  exit 1
fi
grep -F 'already managed; refusing to consume a new enrollment token' "$WORK/replay.log" >/dev/null

# The no-flag path remains the ordinary unmanaged installer: it installs the
# same binaries and config, does not claim a hosted identity, and does not
# auto-start a fresh daemon.
UNMANAGED_HOME="$WORK/unmanaged-home"
mkdir -p "$UNMANAGED_HOME"
PATH="$FAKEBIN:$PATH" HOME="$UNMANAGED_HOME" PILOT_TEST_FIXTURE="$FIXTURE" \
  sh "$ROOT/install.sh" > "$WORK/unmanaged.log" 2>&1
test -x "$UNMANAGED_HOME/.pilot/bin/pilotctl"
test ! -e "$UNMANAGED_HOME/.pilot/managed"
test ! -e "$UNMANAGED_HOME/.pilot/.daemon-running"
grep -F 'GET STARTED' "$WORK/unmanaged.log" >/dev/null
if grep -F 'Managed Pilot node ready:' "$WORK/unmanaged.log" >/dev/null; then
  echo 'ordinary install entered managed mode' >&2
  exit 1
fi

echo "managed installer contract: ok"
