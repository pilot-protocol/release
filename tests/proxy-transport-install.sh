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
#   - proxy credentials never reach the installer output or ~/.pilot;
#   - root reached through sudo/doas is refused, also without systemd;
#   - a daemon that cannot use the proxy is never followed by an instruction
#     to run `pilotctl daemon start` where the proxy is the way out, and a
#     release without auto is not announced as auto (with the compat re-run
#     for UDP-blocked hosts);
#   - the sandbox proxy_cmd is saved only for credentials a fresh shell sees
#     (not for PILOT_PROXY's), and never over an explicit PILOT_PROXY;
#   - restart advice on a proxy-only host stops the running daemon before the
#     recipe starts one; macOS is never sent to the Linux-only recipe, and its
#     LaunchAgent start line carries the same condition as the others;
#   - --transport auto with a daemon that predates auto says what stays saved;
#   - --version / --channel beta install a tag the manifest does not describe
#     (checksums.txt is its anchor), while the manifest hash still has to
#     agree for the tag it describes.
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
# An "ancient" daemon predates -transport altogether.
mkdir -p "$FIXTURE/ancient/archive"
cp "$FIXTURE/old/archive/pilotctl" "$FIXTURE/ancient/archive/pilotctl"
cat > "$FIXTURE/ancient/archive/daemon" <<'SH'
#!/bin/sh
cat <<'HELP'
Usage of pilot-daemon:
  -registry string
    	registry server address
HELP
exit 0
SH
chmod 755 "$FIXTURE"/new/archive/* "$FIXTURE"/old/archive/* "$FIXTURE"/ancient/archive/*

make_release() { # make_release <dir> <tag> [<beta tag> [<manifest sha256> [<platform url tag>]]]
    COPYFILE_DISABLE=1 tar -czf "$1/pilot-linux-amd64.tar.gz" -C "$1/archive" .
    cp "$1/pilot-linux-amd64.tar.gz" "$1/pilot-darwin-amd64.tar.gz" # same fixture binaries
    _sha=$(shasum -a 256 "$1/pilot-linux-amd64.tar.gz" | awk '{print $1}')
    printf '%s  %s\n%s  %s\n' "$_sha" pilot-linux-amd64.tar.gz "$_sha" pilot-darwin-amd64.tar.gz > "$1/checksums.txt"
    _url=""
    if [ -n "${5:-}" ]; then
        _url="\"url\": \"https://github.com/pilot-protocol/pilotprotocol/releases/download/$5/pilot-linux-amd64.tar.gz\", "
    fi
    cat > "$1/stable-manifest.json" <<JSON
{
  "schema_version": 1,
  "latest_stable": "$2",
  "channels": {"stable": "$2", "beta": "${3:-$2}"},
  "platforms": {"linux-amd64": {${_url}"sha256": "${4:-$_sha}"}, "darwin-amd64": {"sha256": "${4:-$_sha}"}}
}
JSON
}
make_release "$FIXTURE/new" v9.9.9
make_release "$FIXTURE/old" v9.9.9
make_release "$FIXTURE/ancient" v9.9.9
# The live manifest's shape: it hashes latest_stable only (its platform url
# names that tag); here that hash is not this archive's, like any other tag's.
OTHER_SHA=0000000000000000000000000000000000000000000000000000000000000000
mkdir -p "$FIXTURE/pinned"
cp -R "$FIXTURE/new/archive" "$FIXTURE/pinned/archive"
make_release "$FIXTURE/pinned" v9.9.9 v9.9.10-rc.1 "$OTHER_SHA" v9.9.9
# The same without urls (a managed-runtime-style manifest): latest_stable only.
mkdir -p "$FIXTURE/pinned-nourl"
cp -R "$FIXTURE/new/archive" "$FIXTURE/pinned-nourl/archive"
make_release "$FIXTURE/pinned-nourl" v9.9.9 v9.9.10-rc.1 "$OTHER_SHA"
# A manifest whose url names the pinned tag: its hash must still agree.
mkdir -p "$FIXTURE/pinned-named"
cp -R "$FIXTURE/new/archive" "$FIXTURE/pinned-named/archive"
make_release "$FIXTURE/pinned-named" v9.9.9 v9.9.10-rc.1 "$OTHER_SHA" v9.9.8

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
  */pilot-darwin-amd64.tar.gz) src="$PILOT_TEST_RELEASE/pilot-darwin-amd64.tar.gz" ;;
  */checksums.txt) src="$PILOT_TEST_RELEASE/checksums.txt" ;;
  *) echo "unexpected curl URL: $url" >&2; exit 88 ;;
esac
cp "$src" "$output"
SH
# Never escalate on the machine running the test.
printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/sudo"
# launchd (PILOT_TEST_UNAME=Darwin cases): nothing is loaded, nothing fails.
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/launchctl"
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
        "${PILOT_TEST_SH:-sh}" "$ROOT/install.sh" "$@" > "$LOG" 2>&1 </dev/null
}

# no_start_command <log> — the log never tells anyone to run the daemon start
# command (a line that starts with it, i.e. an instruction to run it).
no_start_command() {
    if grep -E '^[[:space:]]*(pilotctl daemon (stop && pilotctl daemon )?start|sudo systemctl enable --now pilot-daemon)' "$1" >/dev/null; then
        fail "$2: the output still tells the agent to start the daemon directly"
    fi
}

cfg_get() { # cfg_get <home> <key> — prints the value, "" when absent
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' \
        "$1/.pilot/config.json" "$2"
}

SECRET="s3cretPW"
PROXY="http://muse:${SECRET}@egress.test:3128"
# shellcheck disable=SC2016 # the literal command the installer saves
SANDBOX_CMD='bash -c '\''case $https_proxy in *@*) printf %s "$https_proxy";; *) printf %s "${HTTPS_PROXY:-$https_proxy}";; esac'\'''
unset HTTPS_PROXY https_proxy ALL_PROXY all_proxy PILOT_TRANSPORT PILOT_PROXY_CMD PILOT_ALLOW_ROOT \
      PILOT_PROXY SUDO_USER SUDO_UID SUDO_GID SUDO_COMMAND DOAS_USER PKEXEC_UID 2>/dev/null || true

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
grep -F "Verified SHA-256 (checksums.txt + manifest)" "$WORK/default.log" >/dev/null \
    || fail "latest_stable install was not checked against both anchors"
if grep -F -- "--transport compat" "$WORK/default.log" >/dev/null; then
    fail "a daemon with auto got the UDP-blocked compat hint"
fi

# 2b. A release without auto (v1.13.x) is not announced as auto: the summary
#     says udp, and how to get compat where UDP is blocked.
run_install "$WORK/h-default-old" "$FIXTURE/old" "$WORK/default-old.log" || fail "default install (old daemon)"
if grep -iE 'Transport: +auto' "$WORK/default-old.log" >/dev/null; then
    fail "a release without auto was announced as auto"
fi
grep -F "Transport: udp (this pilot-daemon, v9.9.9, predates auto" "$WORK/default-old.log" >/dev/null \
    || fail "old daemon: transport udp not stated"
grep -F "install.sh | sh -s -- --transport compat" "$WORK/default-old.log" >/dev/null \
    || fail "old daemon: no compat hint for UDP-blocked hosts"
grep -E '^[[:space:]]*pilotctl daemon start --hostname' "$WORK/default-old.log" >/dev/null \
    || fail "a host without a proxy lost the daemon start instruction"
# ...but not when udp was chosen.
run_install "$WORK/h-udp-old" "$FIXTURE/old" "$WORK/udp-old.log" --transport udp || fail "--transport udp (old daemon)"
if grep -F -- "--transport compat" "$WORK/udp-old.log" >/dev/null; then
    fail "--transport udp got the compat hint"
fi

# 3. --transport compat is saved and survives a re-run without --transport;
#    --transport auto then removes it.
run_install "$WORK/h-compat" "$FIXTURE/new" "$WORK/compat.log" --transport compat || fail "compat install"
[ "$(cfg_get "$WORK/h-compat" transport)" = compat ] || fail "--transport compat not saved"
run_install "$WORK/h-compat" "$FIXTURE/new" "$WORK/compat2.log" || fail "compat re-run"
[ "$(cfg_get "$WORK/h-compat" transport)" = compat ] || fail "re-run dropped transport=compat"
run_install "$WORK/h-compat" "$FIXTURE/new" "$WORK/compat3.log" --transport auto || fail "auto re-run"
[ -z "$(cfg_get "$WORK/h-compat" transport)" ] || fail "--transport auto did not remove the saved transport"

# 3b. --transport auto with a daemon that predates auto: nothing to go back
#     to, so the saved compat stays and the output says so (it used to say
#     the daemon "keeps its default (udp)" and then report compat).
run_install "$WORK/h-compat-old" "$FIXTURE/old" "$WORK/compat-old.log" --transport compat || fail "old daemon compat install"
run_install "$WORK/h-compat-old" "$FIXTURE/old" "$WORK/compat-old2.log" --transport auto || fail "old daemon auto re-run"
[ "$(cfg_get "$WORK/h-compat-old" transport)" = compat ] || fail "old daemon: --transport auto changed the saved transport"
grep -F "transport saved in config.json (compat)" "$WORK/compat-old2.log" >/dev/null \
    || fail "old daemon: --transport auto does not say the saved compat stays"
if grep -F "keeps its default (udp)" "$WORK/compat-old2.log" >/dev/null; then
    fail "old daemon: --transport auto claims udp while compat stays saved"
fi
grep -F "Transport: compat" "$WORK/compat-old2.log" >/dev/null || fail "old daemon: summary does not report the saved compat"

# 4. Sandbox (Linux without systemd) with a credential-bearing HTTPS_PROXY:
#    proxy_cmd is saved and the credentials never reach the output.
if [ ! -d /run/systemd/system ]; then
    LOG="$WORK/sandbox.log"
    (export HTTPS_PROXY="$PROXY" https_proxy="$PROXY"
     run_install "$WORK/h-sandbox" "$FIXTURE/new" "$LOG") || fail "sandbox install"
    [ "$(cfg_get "$WORK/h-sandbox" proxy_cmd)" = "$SANDBOX_CMD" ] || fail "proxy_cmd not saved in a sandbox: '$(cfg_get "$WORK/h-sandbox" proxy_cmd)'"
    grep -F 'http://***@egress.test:3128' "$LOG" >/dev/null || fail "proxy not shown redacted"
    # A daemon that uses the proxy is started the ordinary way.
    grep -E '^[[:space:]]*pilotctl daemon start --hostname' "$LOG" >/dev/null \
        || fail "a daemon that can use the proxy lost the daemon start instruction"
    if grep -F "pilot-sandbox recipe" "$LOG" >/dev/null; then
        fail "a daemon that can use the proxy was sent to the sandbox recipe"
    fi
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
    # The proxy is the way out (its credentials rotate): nothing tells the
    # agent to run `pilotctl daemon start`, which would dial the registry
    # around the proxy; GET STARTED points at the recipe instead.
    no_start_command "$LOG" "old daemon in a proxy-only sandbox"
    # shellcheck disable=SC2016 # literal backquotes
    grep -F 'Do NOT run `pilotctl daemon start` on this host' "$LOG" >/dev/null \
        || fail "GET STARTED does not warn against pilotctl daemon start"
    [ "$(grep -c -F "https://pilotprotocol.network/learn/install-pilot-skills-in-meta-muse" "$LOG")" -ge 3 ] \
        || fail "the warning, the no-systemd hint and GET STARTED do not all point at the recipe"
    if grep -iE 'Transport: +auto' "$LOG" >/dev/null; then fail "old daemon announced as auto (sandbox)"; fi
    if grep -F -- "--transport compat" "$LOG" >/dev/null; then
        fail "the compat hint was shown where compat cannot use the proxy either"
    fi
    if grep -F "restart the daemon from a fresh shell" "$LOG" >/dev/null; then
        fail "a daemon that cannot use a proxy was told to refresh proxy credentials"
    fi
    # A re-run (update) does not tell it to restart the daemon directly either.
    LOG="$WORK/oldcmd-rerun.log"
    (export HTTPS_PROXY="$PROXY"
     run_install "$WORK/h-oldcmd" "$FIXTURE/old" "$LOG") || fail "old daemon sandbox re-run"
    no_start_command "$LOG" "old daemon sandbox re-run"
    grep -F "https://pilotprotocol.network/learn/install-pilot-skills-in-meta-muse" "$LOG" >/dev/null \
        || fail "the re-run does not point at the recipe"
    # The recipe starts a daemon but never stops one: the restart advice
    # must stop the running one first, or following it runs two daemons
    # with one identity.
    grep -F "Stop the running daemon first: pilotctl daemon stop" "$LOG" >/dev/null \
        || fail "the re-run advice dropped \`pilotctl daemon stop\` before the recipe"
    LOG="$WORK/oldcmd.log"
    # --transport compat on the same host: same story.
    LOG="$WORK/oldcmd-compat.log"
    (export HTTPS_PROXY="$PROXY"
     run_install "$WORK/h-oldcmd-compat" "$FIXTURE/old" "$LOG" --transport compat) || fail "old daemon sandbox compat install"
    no_start_command "$LOG" "old daemon, compat, proxy-only sandbox"
    LOG="$WORK/oldcmd.log"

    # A proxy without credentials may not be the only way out: the start
    # command stays, with the condition and the recipe next to it.
    LOG="$WORK/old-nocreds.log"
    (export HTTPS_PROXY=http://egress.test:3128
     run_install "$WORK/h-old-nocreds" "$FIXTURE/old" "$LOG") || fail "old daemon, proxy without credentials"
    grep -F "skip the next line; what works then:" "$LOG" >/dev/null \
        || fail "no condition next to the start command (proxy without credentials)"
    grep -E '^[[:space:]]*pilotctl daemon start --hostname' "$LOG" >/dev/null \
        || fail "the start command was dropped for a proxy that may not be the only way out"
    LOG="$WORK/oldcmd.log"

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

    # 4d. Credentials that come from PILOT_PROXY never reach a fresh shell,
    #     so the sandbox proxy command (which prints a fresh shell's
    #     $https_proxy / $HTTPS_PROXY) is not saved and rotation is not
    #     claimed; nor does it replace an explicit PILOT_PROXY next to a
    #     credential-bearing HTTPS_PROXY (the daemon runs a proxy command in
    #     place of the URL it would use).
    LOG="$WORK/pilot-proxy-creds.log"
    (export PILOT_PROXY="$PROXY"
     run_install "$WORK/h-pilot-proxy-creds" "$FIXTURE/new" "$LOG") || fail "PILOT_PROXY with credentials"
    [ -z "$(cfg_get "$WORK/h-pilot-proxy-creds" proxy_cmd)" ] || fail "sandbox proxy_cmd saved for credentials that come from PILOT_PROXY"
    if grep -F -e "re-read by the daemon" -e "rotation needs no restart" "$LOG" >/dev/null; then
        fail "rotation claimed for credentials that come from PILOT_PROXY"
    fi
    if grep -F "$SECRET" "$LOG" >/dev/null || grep -rF "$SECRET" "$WORK/h-pilot-proxy-creds/.pilot" >/dev/null; then
        fail "proxy credentials leaked (PILOT_PROXY)"
    fi
    LOG="$WORK/pilot-proxy-explicit.log"
    (export PILOT_PROXY=http://relay.test:3128 HTTPS_PROXY="$PROXY"
     run_install "$WORK/h-pilot-proxy-explicit" "$FIXTURE/new" "$LOG") || fail "explicit PILOT_PROXY next to HTTPS_PROXY"
    [ -z "$(cfg_get "$WORK/h-pilot-proxy-explicit" proxy_cmd)" ] || fail "sandbox proxy_cmd saved over an explicit PILOT_PROXY"

    # 5. Root: allowed in a Linux container/VM without systemd.
    LOG="$WORK/root.log"
    (export PILOT_TEST_UID=0 HTTPS_PROXY="$PROXY"
     run_install "$WORK/h-root" "$FIXTURE/new" "$LOG") || fail "root install in a sandbox was refused"
    grep -F "installing as root (no systemd" "$LOG" >/dev/null || fail "no root note"
    [ -x "$WORK/h-root/.pilot/bin/pilotctl" ] || fail "root install did not install pilotctl"
    [ "$(cfg_get "$WORK/h-root" proxy_cmd)" = "$SANDBOX_CMD" ] || fail "root sandbox install did not save proxy_cmd"

    # sudo run by root itself (SUDO_UID=0) is still root's own install.
    LOG="$WORK/root-sudo-root.log"
    (export PILOT_TEST_UID=0 SUDO_USER=root SUDO_UID=0
     run_install "$WORK/h-root-sudo-root" "$FIXTURE/new" "$LOG") || fail "root via sudo from root was refused"
    # PILOT_ALLOW_ROOT=1 still overrides the sudo refusal.
    LOG="$WORK/root-sudo-allow.log"
    (export PILOT_TEST_UID=0 SUDO_USER=agent SUDO_UID=1000 PILOT_ALLOW_ROOT=1
     run_install "$WORK/h-root-sudo-allow" "$FIXTURE/new" "$LOG") || fail "PILOT_ALLOW_ROOT=1 did not override the sudo refusal"
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

# 9b. compat with a daemon that predates -transport: the summary does not
#     claim compat.
run_install "$WORK/h-ancient" "$FIXTURE/ancient" "$WORK/ancient.log" --transport compat || fail "ancient daemon compat install"
grep -F "predates compat mode" "$WORK/ancient.log" >/dev/null || fail "ancient daemon: no compat warning"
grep -F "Transport: udp (compat is saved, but this pilot-daemon" "$WORK/ancient.log" >/dev/null \
    || fail "ancient daemon: the summary claims compat"

# 10. Root on macOS is refused like on any host with a service manager.
LOG="$WORK/root-mac.log"
if (export PILOT_TEST_UID=0 PILOT_TEST_UNAME=Darwin; run_install "$WORK/h-root-mac" "$FIXTURE/new" "$LOG"); then
    fail "root install on macOS was accepted"
fi
grep -F "refusing to install as root" "$LOG" >/dev/null || fail "no root refusal on macOS"

# 10a. macOS with a proxy this release cannot use: the LaunchAgent start
#      line carries the same condition as every other start line, and
#      nothing points at the Linux-root-only sandbox recipe.
LOG="$WORK/mac-proxy.log"
(export PILOT_TEST_UNAME=Darwin HTTPS_PROXY="$PROXY"
 run_install "$WORK/h-mac-proxy" "$FIXTURE/old" "$LOG") || fail "macOS install behind a proxy (old daemon)"
grep -F "cannot use one" "$LOG" >/dev/null || fail "macOS: no warning about a proxy the old daemon cannot use"
if grep -F "pilot-sandbox recipe (step 3)" "$LOG" >/dev/null; then
    fail "macOS was sent to the Linux-only pilot-sandbox recipe"
fi
if grep -E '^[[:space:]]*Start daemon: launchctl load' "$LOG" >/dev/null; then
    fail "macOS: the LaunchAgent start line has no condition next to it"
fi
grep -F "it will not come online with" "$LOG" >/dev/null || fail "macOS: no condition next to the LaunchAgent start line"
grep -F "lists -proxy" "$LOG" >/dev/null || fail "macOS: no way forward named"
LOG="$WORK/mac-proxy-cmd.log"
(export PILOT_TEST_UNAME=Darwin HTTPS_PROXY="$PROXY" PILOT_PROXY_CMD='cat /run/proxy-url'
 run_install "$WORK/h-mac-proxy-cmd" "$FIXTURE/old" "$LOG") || fail "macOS install, PILOT_PROXY_CMD (old daemon)"
if grep -E '^[[:space:]]*(launchctl load|Start daemon: launchctl load)' "$LOG" >/dev/null; then
    fail "macOS proxy-only: still told to load the LaunchAgent"
fi
# shellcheck disable=SC2016 # literal backquotes
grep -F 'Do not run `launchctl load -w' "$LOG" >/dev/null || fail "macOS proxy-only: no warning against loading the LaunchAgent"
if grep -F "pilot-sandbox recipe (step 3)" "$LOG" >/dev/null; then
    fail "macOS proxy-only was sent to the Linux-only pilot-sandbox recipe"
fi
if grep -F "$SECRET" "$LOG" >/dev/null; then fail "proxy credentials leaked (macOS)"; fi

# 10b. Root through sudo/doas for a regular user is refused, with or without
#      systemd: that user could not use a node installed for root.
for _elev in "SUDO_USER=agent SUDO_UID=1000" "SUDO_USER=agent" "DOAS_USER=agent"; do
    LOG="$WORK/root-elev.log"
    rm -rf "$WORK/h-root-elev"
    # shellcheck disable=SC2086,SC2163 # intentional split into NAME=value words
    if (export PILOT_TEST_UID=0 $_elev; run_install "$WORK/h-root-elev" "$FIXTURE/new" "$LOG"); then
        fail "root install under '$_elev' was accepted"
    fi
    grep -F "refusing to install as root: this runs under" "$LOG" >/dev/null || fail "no sudo refusal ($_elev)"
    grep -F "for agent" "$LOG" >/dev/null || fail "the sudo refusal does not name the user ($_elev)"
    [ ! -e "$WORK/h-root-elev/.pilot" ] || fail "refused sudo install left ~/.pilot behind ($_elev)"
done

# 10c. --version / --channel beta: a tag the manifest does not describe is
#      checked against checksums.txt alone (previously: "integrity anchors
#      disagree" for every tag but latest_stable).
for _mf in pinned pinned-nourl; do
    run_install "$WORK/h-pin-$_mf" "$FIXTURE/$_mf" "$WORK/pin-$_mf.log" --version v9.9.8 --yes \
        || fail "--version v9.9.8 ($_mf manifest) was refused"
    grep -F "Verified SHA-256 (checksums.txt)" "$WORK/pin-$_mf.log" >/dev/null \
        || fail "--version v9.9.8 ($_mf manifest): not verified against checksums.txt"
    [ "$(cat "$WORK/h-pin-$_mf/.pilot/bin/.pilot-version")" = v9.9.8 ] || fail "--version v9.9.8 ($_mf): wrong version file"
    run_install "$WORK/h-beta-$_mf" "$FIXTURE/$_mf" "$WORK/beta-$_mf.log" --channel beta \
        || fail "--channel beta ($_mf manifest) was refused"
    grep -F "Downloading v9.9.10-rc.1" "$WORK/beta-$_mf.log" >/dev/null || fail "--channel beta did not resolve the beta tag"
    # The tag the manifest describes still needs both anchors to agree.
    if run_install "$WORK/h-latest-$_mf" "$FIXTURE/$_mf" "$WORK/latest-$_mf.log" --version v9.9.9; then
        fail "a manifest hash that disagrees was ignored for latest_stable ($_mf)"
    fi
    grep -F "integrity anchors disagree" "$WORK/latest-$_mf.log" >/dev/null || fail "no anchor mismatch error ($_mf)"
done
# A manifest whose platform url names the pinned tag is an anchor for it.
if run_install "$WORK/h-pin-named" "$FIXTURE/pinned-named" "$WORK/pin-named.log" --version v9.9.8 --yes; then
    fail "a manifest hash for the pinned tag that disagrees was ignored"
fi
grep -F "integrity anchors disagree" "$WORK/pin-named.log" >/dev/null || fail "no anchor mismatch error (url names the tag)"

# 11. --help prints the whole usage header and nothing past it.
"${PILOT_TEST_SH:-sh}" "$ROOT/install.sh" --help > "$WORK/help.log" 2>&1 || fail "--help failed"
grep -F -- "--transport <mode>" "$WORK/help.log" >/dev/null || fail "--help lacks --transport"
grep -F "with a message, never fatal." "$WORK/help.log" >/dev/null || fail "--help cut the header short"
if grep -F "WHAT THIS SCRIPT DOES" "$WORK/help.log" >/dev/null; then fail "--help printed past the usage header"; fi

if [ -n "${PILOT_TEST_KEEP:-}" ]; then echo "logs kept in $WORK"; else rm -rf "$WORK"; fi
echo "proxy/transport installer contract: ok"
