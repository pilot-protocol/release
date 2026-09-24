#!/bin/sh
# Contract test for the transport / proxy / sandbox handling in install.sh:
#   - root is allowed in a Linux container/VM without systemd (hosted agent
#     sandboxes such as Meta Muse run the agent as root), refused elsewhere;
#   - --transport udp|compat is saved in config.json, auto never is, and
#     --transport auto removes a saved transport;
#   - proxy_cmd is saved in such a sandbox when HTTPS_PROXY carries
#     credentials (the daemon re-reads rotating proxy credentials with it),
#     also for a daemon that predates -proxy-cmd (it ignores the key until
#     upgraded);
#   - a download that fails because the proxy credentials rotated mid-install
#     is retried once with the credentials a fresh shell sees;
#   - PILOT_PROXY carries the downloads when no *_PROXY variable is set;
#   - no raw-IP registry/beacon is written for compat, or auto behind a proxy
#     (an older pilotctl in compat mode gets the TLS registry by name);
#   - a saved transport=auto is rewritten to udp for a daemon that predates it;
#   - proxy credentials never reach the installer output or ~/.pilot.
#
# Like tests/managed-install.sh it installs a fixture release through a fake
# curl, so it needs no network. It never uses sudo (a fake sudo fails), and the
# root cases fake `id -u`; run it in a disposable container to also exercise
# the /usr/local/bin links as real root.
# The per-run environment is set in subshells on purpose (see run_install).
# shellcheck disable=SC2030,SC2031
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pilot-proxy-install-test.XXXXXX")
FIXTURE="$WORK/fixture"
FAKEBIN="$WORK/fakebin"
mkdir -p "$FIXTURE/new/archive" "$FIXTURE/old/archive" "$FAKEBIN"

fail() {
    echo "FAIL: $*" >&2
    [ -n "${LOG:-}" ] && [ -f "$LOG" ] && sed 's/^/  | /' "$LOG" >&2
    exit 1
}

# --- Fixture binaries ---------------------------------------------------------

# pilot-daemon: only -help matters to the installer. The "new" daemon has
# -transport (with 'auto'), -proxy and -proxy-cmd; the "old" one predates auto,
# -proxy and -proxy-cmd (v1.13.x).
cat > "$FIXTURE/new/archive/daemon" <<'SH'
#!/bin/sh
cat <<'HELP'
Usage of pilot-daemon:
  -proxy string
    	Outbound proxy: 'auto', 'off' or an http(s):// URL. Env: PILOT_PROXY.
  -proxy-cmd string
    	Command printing the current proxy URL. Env: PILOT_PROXY_CMD.
  -registry string
    	registry server address
  -transport string
    	Tunnel transport: 'udp', 'compat' or 'auto'
HELP
exit 0
SH
cat > "$FIXTURE/old/archive/daemon" <<'SH'
#!/bin/sh
cat <<'HELP'
Usage of pilot-daemon:
  -registry string
    	registry server address
  -transport string
    	Tunnel transport: 'udp' (default) or 'compat' (TCP/443)
HELP
exit 0
SH
# pilotctl: `config --set key=value` edits $HOME/.pilot/config.json the way the
# real one does (an empty value removes the key); everything else succeeds.
cat > "$FIXTURE/new/archive/pilotctl" <<'SH'
#!/bin/sh
case "$*" in
  "config --set "*)
    kv="${3:-}"
    python3 - "$HOME/.pilot/config.json" "$kv" <<'PY'
import json, os, sys
path, kv = sys.argv[1], sys.argv[2]
k, _, v = kv.partition("=")
try:
    with open(path) as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
if v == "":
    cfg.pop(k, None)
else:
    cfg[k] = v
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PY
    ;;
  "daemon start --help")
    echo "  --transport <udp|compat|auto>"
    ;;
  version)
    echo v9.9.9
    ;;
  *)
    exit 0
    ;;
esac
SH
# The "old" pilotctl predates `daemon start --transport` (v1.13.x).
sed 's/--transport <udp|compat|auto>/--registry <addr>/' "$FIXTURE/new/archive/pilotctl" > "$FIXTURE/old/archive/pilotctl"
chmod 755 "$FIXTURE"/new/archive/* "$FIXTURE"/old/archive/*

make_release() { # make_release <dir> <tag>
    COPYFILE_DISABLE=1 tar -czf "$1/pilot-linux-amd64.tar.gz" -C "$1/archive" .
    _sha=$(shasum -a 256 "$1/pilot-linux-amd64.tar.gz" | awk '{print $1}')
    printf '%s  %s\n' "$_sha" pilot-linux-amd64.tar.gz > "$1/checksums.txt"
    cat > "$1/stable-manifest.json" <<JSON
{
  "schema_version": 1,
  "latest_stable": "$2",
  "channels": {"stable": "$2", "beta": "$2"},
  "platforms": {"linux-amd64": {"sha256": "$_sha"}}
}
JSON
}
make_release "$FIXTURE/new" v9.9.9
make_release "$FIXTURE/old" v9.9.9

# --- Fake system tools ----------------------------------------------------------

cat > "$FAKEBIN/uname" <<'SH'
#!/bin/sh
case "${1:-}" in
  -m) echo x86_64 ;;
  *) echo "${PILOT_TEST_UNAME:-Linux}" ;;
esac
SH
cat > "$FAKEBIN/curl" <<'SH'
#!/bin/sh
: "${PILOT_TEST_RELEASE:?}"
url=""
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    --max-time|-w) shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$output" ] || exit 89
# PILOT_TEST_EXPECT_PROXY: the proxy this download must go through.
if [ -n "${PILOT_TEST_EXPECT_PROXY:-}" ] && [ "${https_proxy:-}" != "$PILOT_TEST_EXPECT_PROXY" ]; then
  echo "download not through the expected proxy" >&2; exit 5
fi
# PILOT_TEST_CREDS: file holding the proxy password that is valid right now.
# A request with any other one gets curl's 407 failure (exit 56). After the
# manifest is served the password rotates once.
if [ -n "${PILOT_TEST_CREDS:-}" ]; then
  _pw=${https_proxy#*://*:}; _pw=${_pw%%@*}
  if [ "$_pw" != "$(cat "$PILOT_TEST_CREDS")" ]; then
    echo 407 >> "$PILOT_TEST_CREDS.rejected"
    echo "curl: (56) CONNECT tunnel failed, response 407" >&2; exit 56
  fi
  case "$url" in
    */.well-known/latest.json)
      if [ ! -e "$PILOT_TEST_CREDS.rotated" ]; then
        : > "$PILOT_TEST_CREDS.rotated"
        printf 'rotated-%s\n' "$(cat "$PILOT_TEST_CREDS")" > "$PILOT_TEST_CREDS.new"
        mv "$PILOT_TEST_CREDS.new" "$PILOT_TEST_CREDS"
      fi ;;
  esac
fi
case "$url" in
  */.well-known/latest.json) src="$PILOT_TEST_RELEASE/stable-manifest.json" ;;
  */pilot-linux-amd64.tar.gz) src="$PILOT_TEST_RELEASE/pilot-linux-amd64.tar.gz" ;;
  */checksums.txt) src="$PILOT_TEST_RELEASE/checksums.txt" ;;
  *) echo "unexpected curl URL: $url" >&2; exit 88 ;;
esac
cp "$src" "$output"
SH
# Never escalate on the machine running the test.
printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/sudo"
# `id -u` answers $PILOT_TEST_UID when set.
REAL_ID=$(command -v id)
cat > "$FAKEBIN/id" <<SH
#!/bin/sh
if [ "\${1:-}" = "-u" ] && [ -n "\${PILOT_TEST_UID:-}" ]; then echo "\$PILOT_TEST_UID"; exit 0; fi
exec "$REAL_ID" "\$@"
SH
chmod 755 "$FAKEBIN"/*

# run_install <home> <release dir> <log> [installer args...] — the caller's
# environment passes through. Callers that set variables for one run do it in
# a subshell: under bash's POSIX mode (macOS sh) an assignment prefixing a
# function call outlives the call.
run_install() {
    _home="$1"; _rel="$2"; LOG="$3"; shift 3
    mkdir -p "$_home"
    PATH="$FAKEBIN:$PATH" HOME="$_home" PILOT_TEST_RELEASE="$_rel" \
        PILOT_EMAIL=ci@example.com \
        sh "$ROOT/install.sh" "$@" > "$LOG" 2>&1
}

cfg_get() { # cfg_get <home> <key> — prints the value, "" when absent
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' \
        "$1/.pilot/config.json" "$2"
}

SECRET="s3cretPW"
PROXY="http://muse:${SECRET}@egress.test:3128"
# shellcheck disable=SC2016 # the literal command the installer saves
SANDBOX_CMD='bash -c '\''case $https_proxy in *@*) printf %s "$https_proxy";; *) printf %s "${HTTPS_PROXY:-$https_proxy}";; esac'\'''
unset HTTPS_PROXY https_proxy ALL_PROXY all_proxy PILOT_TRANSPORT PILOT_PROXY_CMD PILOT_ALLOW_ROOT 2>/dev/null || true

# 1. --transport is validated.
if run_install "$WORK/h-bad" "$FIXTURE/new" "$WORK/bad.log" --transport quic; then
    fail "--transport quic was accepted"
fi
grep -F "must be 'udp', 'compat' or 'auto'" "$WORK/bad.log" >/dev/null || fail "no --transport error"

# 2. Default install: auto is not saved; no proxy -> no proxy_cmd.
run_install "$WORK/h-default" "$FIXTURE/new" "$WORK/default.log" || fail "default install"
[ -z "$(cfg_get "$WORK/h-default" transport)" ] || fail "default install saved a transport"
[ -z "$(cfg_get "$WORK/h-default" proxy_cmd)" ] || fail "default install saved proxy_cmd"
grep -F "Transport: auto" "$WORK/default.log" >/dev/null || fail "default install did not report transport auto"

# 3. --transport compat is saved and survives a re-run without --transport;
#    --transport auto then removes it.
run_install "$WORK/h-compat" "$FIXTURE/new" "$WORK/compat.log" --transport compat || fail "compat install"
[ "$(cfg_get "$WORK/h-compat" transport)" = compat ] || fail "--transport compat not saved"
run_install "$WORK/h-compat" "$FIXTURE/new" "$WORK/compat2.log" || fail "compat re-run"
[ "$(cfg_get "$WORK/h-compat" transport)" = compat ] || fail "re-run dropped transport=compat"
run_install "$WORK/h-compat" "$FIXTURE/new" "$WORK/compat3.log" --transport auto || fail "auto re-run"
[ -z "$(cfg_get "$WORK/h-compat" transport)" ] || fail "--transport auto did not remove the saved transport"

# 4. Sandbox (Linux without systemd) with a credential-bearing HTTPS_PROXY:
#    proxy_cmd is saved and the credentials never reach the output.
if [ ! -d /run/systemd/system ]; then
    LOG="$WORK/sandbox.log"
    (export HTTPS_PROXY="$PROXY" https_proxy="$PROXY"
     run_install "$WORK/h-sandbox" "$FIXTURE/new" "$LOG") || fail "sandbox install"
    [ "$(cfg_get "$WORK/h-sandbox" proxy_cmd)" = "$SANDBOX_CMD" ] || fail "proxy_cmd not saved in a sandbox: '$(cfg_get "$WORK/h-sandbox" proxy_cmd)'"
    grep -F 'http://***@egress.test:3128' "$LOG" >/dev/null || fail "proxy not shown redacted"
    if grep -F "$SECRET" "$LOG" "$WORK/h-sandbox/.pilot/config.json" >/dev/null; then
        fail "proxy credentials leaked"
    fi

    # An explicit PILOT_PROXY_CMD wins; an existing proxy_cmd is never replaced.
    LOG="$WORK/sandbox2.log"
    (export PILOT_PROXY_CMD='cat /run/proxy-url' HTTPS_PROXY="$PROXY"
     run_install "$WORK/h-sandbox2" "$FIXTURE/new" "$LOG") || fail "PILOT_PROXY_CMD install"
    [ "$(cfg_get "$WORK/h-sandbox2" proxy_cmd)" = 'cat /run/proxy-url' ] || fail "PILOT_PROXY_CMD not saved"
    LOG="$WORK/sandbox3.log"
    (export HTTPS_PROXY="$PROXY"
     run_install "$WORK/h-sandbox2" "$FIXTURE/new" "$LOG") || fail "sandbox re-run"
    [ "$(cfg_get "$WORK/h-sandbox2" proxy_cmd)" = 'cat /run/proxy-url' ] || fail "re-run replaced proxy_cmd"

    # A proxy without credentials has nothing to rotate.
    LOG="$WORK/nocreds.log"
    (export HTTPS_PROXY=http://egress.test:3128
     run_install "$WORK/h-nocreds" "$FIXTURE/new" "$LOG") || fail "no-creds install"
    [ -z "$(cfg_get "$WORK/h-nocreds" proxy_cmd)" ] || fail "proxy_cmd saved for a proxy without credentials"

    # A daemon without -proxy-cmd (v1.13.x): proxy_cmd is still saved (the
    # daemon ignores it until upgraded), with a note, and the proxy it cannot
    # use is called out with the recipe that works.
    LOG="$WORK/oldcmd.log"
    (export HTTPS_PROXY="$PROXY"
     run_install "$WORK/h-oldcmd" "$FIXTURE/old" "$LOG") || fail "old daemon sandbox install"
    [ "$(cfg_get "$WORK/h-oldcmd" proxy_cmd)" = "$SANDBOX_CMD" ] || fail "proxy_cmd not saved for a daemon without -proxy-cmd"
    grep -F "predates -proxy-cmd" "$LOG" >/dev/null || fail "no -proxy-cmd note for an old daemon"
    grep -F "cannot use one" "$LOG" >/dev/null || fail "no warning about a proxy the old daemon cannot use"
    grep -F "https://pilotprotocol.network/learn/install-pilot-skills-in-meta-muse" "$LOG" >/dev/null \
        || fail "the old-daemon proxy warning does not point at the sandbox recipe"
    # auto is not supported, so the daemon runs udp: the stock endpoints stay.
    [ "$(cfg_get "$WORK/h-oldcmd" registry)" = "34.71.57.205:9000" ] || fail "udp install lost the raw registry"
    if grep -F "$SECRET" "$LOG" >/dev/null || grep -rF "$SECRET" "$WORK/h-oldcmd/.pilot" >/dev/null; then
        fail "proxy credentials leaked (old daemon)"
    fi

    # Credentials that rotate while the installer runs: the download that
    # gets the 407 is retried once with what a fresh bash sees (BASH_ENV
    # stands in for the sandbox's mechanism), and nothing is printed.
    if command -v bash >/dev/null 2>&1; then
        CREDS="$WORK/creds"
        printf 'gen1pw\n' > "$CREDS"
        cat > "$WORK/bash_env.sh" <<ENV
_p=\$(cat "$CREDS")
export https_proxy="http://muse:\${_p}@egress.test:3128" HTTPS_PROXY="http://muse:\${_p}@egress.test:3128"
ENV
        LOG="$WORK/rotate.log"
        (export PILOT_TEST_CREDS="$CREDS" BASH_ENV="$WORK/bash_env.sh" \
                HTTPS_PROXY="http://muse:gen1pw@egress.test:3128" https_proxy="http://muse:gen1pw@egress.test:3128"
         run_install "$WORK/h-rotate" "$FIXTURE/new" "$LOG") || fail "install across a credential rotation"
        [ -s "$CREDS.rejected" ] || fail "the rotation was not exercised (no 407)"
        grep -F "Verified SHA-256" "$LOG" >/dev/null || fail "rotated install did not verify the archive"
        if grep -F -e gen1pw -e rotated-gen1pw "$LOG" >/dev/null \
           || grep -rF -e gen1pw "$WORK/h-rotate/.pilot" >/dev/null; then
            fail "proxy credentials leaked (rotation)"
        fi
    else
        echo "skip: rotation case needs bash"
    fi

    # 4b. Compat / auto behind a proxy: no raw-IP registry or beacon in
    #     config.json (the daemon picks the TLS registry itself), and no
    #     credentials anywhere under ~/.pilot.
    LOG="$WORK/auto-proxy.log"
    (export HTTPS_PROXY="$PROXY" https_proxy="$PROXY"
     run_install "$WORK/h-auto-proxy" "$FIXTURE/new" "$LOG") || fail "auto install behind a proxy"
    if grep -F "34.71.57.205" "$WORK/h-auto-proxy/.pilot/config.json" >/dev/null; then
        fail "auto install behind a proxy wrote a raw-IP endpoint"
    fi
    [ -z "$(cfg_get "$WORK/h-auto-proxy" transport)" ] || fail "auto install saved a transport"
    if grep -F "$SECRET" "$LOG" >/dev/null || grep -rF "$SECRET" "$WORK/h-auto-proxy/.pilot" >/dev/null; then
        fail "proxy credentials leaked (auto behind a proxy)"
    fi

    LOG="$WORK/compat-proxy.log"
    (export HTTPS_PROXY="$PROXY" https_proxy="$PROXY"
     run_install "$WORK/h-compat-proxy" "$FIXTURE/new" "$LOG" --transport compat) || fail "compat install behind a proxy"
    if grep -F "34.71.57.205" "$WORK/h-compat-proxy/.pilot/config.json" >/dev/null; then
        fail "compat install wrote a raw-IP endpoint"
    fi
    [ "$(cfg_get "$WORK/h-compat-proxy" transport)" = compat ] || fail "compat not saved (proxy)"

    # 4c. PILOT_PROXY carries the downloads when no *_PROXY is set.
    LOG="$WORK/pilot-proxy.log"
    (export PILOT_PROXY=http://relay.test:3128 PILOT_TEST_EXPECT_PROXY=http://relay.test:3128
     run_install "$WORK/h-pilot-proxy" "$FIXTURE/new" "$LOG") || fail "downloads did not use PILOT_PROXY"

    # 5. Root: allowed in a Linux container/VM without systemd.
    LOG="$WORK/root.log"
    (export PILOT_TEST_UID=0 HTTPS_PROXY="$PROXY"
     run_install "$WORK/h-root" "$FIXTURE/new" "$LOG") || fail "root install in a sandbox was refused"
    grep -F "installing as root (no systemd" "$LOG" >/dev/null || fail "no root note"
    [ -x "$WORK/h-root/.pilot/bin/pilotctl" ] || fail "root install did not install pilotctl"
    [ "$(cfg_get "$WORK/h-root" proxy_cmd)" = "$SANDBOX_CMD" ] || fail "root sandbox install did not save proxy_cmd"
else
    # 5b. Root on a host with systemd is still refused (PILOT_ALLOW_ROOT=1 overrides).
    LOG="$WORK/root.log"
    if (export PILOT_TEST_UID=0; run_install "$WORK/h-root" "$FIXTURE/new" "$LOG"); then
        fail "root install on a systemd host was accepted"
    fi
    grep -F "refusing to install as root" "$LOG" >/dev/null || fail "no root refusal"
    [ ! -e "$WORK/h-root/.pilot" ] || fail "refused root install left ~/.pilot behind"
    echo "skip: sandbox cases need a host without /run/systemd/system"
fi

# 6. Downgrade: a saved transport=auto is rewritten to udp for a daemon that
#    predates auto (it would refuse to start).
mkdir -p "$WORK/h-down/.pilot"
printf '{\n  "registry": "34.71.57.205:9000",\n  "transport": "auto"\n}\n' > "$WORK/h-down/.pilot/config.json"
run_install "$WORK/h-down" "$FIXTURE/old" "$WORK/down.log" || fail "downgrade install"
[ "$(cfg_get "$WORK/h-down" transport)" = udp ] || fail "transport=auto not rewritten to udp for an old daemon"

# 7. Leaving compat restores the raw-TCP registry an older compat install saved.
mkdir -p "$WORK/h-back/.pilot"
printf '{\n  "registry": "registry.pilotprotocol.network:443",\n  "transport": "compat"\n}\n' > "$WORK/h-back/.pilot/config.json"
run_install "$WORK/h-back" "$FIXTURE/new" "$WORK/back.log" --transport udp || fail "switch-back install"
[ "$(cfg_get "$WORK/h-back" transport)" = udp ] || fail "--transport udp not saved"
[ "$(cfg_get "$WORK/h-back" registry)" = "34.71.57.205:9000" ] || fail "raw registry not restored"

# 8. Without a proxy the stock endpoints are written as before (auto or udp).
[ "$(cfg_get "$WORK/h-default" registry)" = "34.71.57.205:9000" ] || fail "default install lost the raw registry"
[ "$(cfg_get "$WORK/h-default" beacon)" = "34.71.57.205:9001" ] || fail "default install lost the raw beacon"

# 9. compat with a pilotctl that predates --transport (it passes config.json's
#    registry to the daemon verbatim): the TLS registry is written by name.
run_install "$WORK/h-oldctl" "$FIXTURE/old" "$WORK/oldctl.log" --transport compat || fail "old pilotctl compat install"
[ "$(cfg_get "$WORK/h-oldctl" registry)" = "registry.pilotprotocol.network:443" ] \
    || fail "old pilotctl compat install: registry '$(cfg_get "$WORK/h-oldctl" registry)'"
if grep -F "34.71.57.205" "$WORK/h-oldctl/.pilot/config.json" >/dev/null; then
    fail "old pilotctl compat install wrote a raw-IP endpoint"
fi

# 10. Root on macOS is refused like on any host with a service manager.
LOG="$WORK/root-mac.log"
if (export PILOT_TEST_UID=0 PILOT_TEST_UNAME=Darwin; run_install "$WORK/h-root-mac" "$FIXTURE/new" "$LOG"); then
    fail "root install on macOS was accepted"
fi
grep -F "refusing to install as root" "$LOG" >/dev/null || fail "no root refusal on macOS"

# 11. --help prints the whole usage header and nothing past it.
sh "$ROOT/install.sh" --help > "$WORK/help.log" 2>&1 || fail "--help failed"
grep -F -- "--transport <mode>" "$WORK/help.log" >/dev/null || fail "--help lacks --transport"
grep -F "with a message, never fatal." "$WORK/help.log" >/dev/null || fail "--help cut the header short"
if grep -F "WHAT THIS SCRIPT DOES" "$WORK/help.log" >/dev/null; then fail "--help printed past the usage header"; fi

rm -rf "$WORK"
echo "proxy/transport installer contract: ok"
