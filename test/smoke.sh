#!/usr/bin/env bash
#
# End-to-end smoke test for freeunit-drupal: optionally build, then assert:
#   (a) web role  -- FreeUnit serves PHP, on the expected PHP line, as the app user
#   (b) toolchain -- composer, supercronic, git, mariadb-client, patch present
#   (c) cron role -- supercronic command runs jobs as the app user
#   (d) any uid   -- the cron role under a uid with no passwd entry
# The cron and any-uid roles run the image's /docker-entrypoint.d scripts
# without their variables: they must do nothing. The web role mounts its own
# /docker-entrypoint.d over them.
# Both roles run read-only, with every capability dropped and only /run and
# /tmp writable, as the image user: every process must run as that user and
# the logs must carry no write or privilege error.
#
#   ./test/smoke.sh freeunit-drupal:local-php8.4          # test a prebuilt image
#   ./test/smoke.sh --build freeunit-drupal:local-php8.4  # build it first, then test
#   ./test/smoke.sh --build --php 8.3 freeunit-drupal:dev # build a chosen PHP line

set -euo pipefail

usage() {
    cat <<EOF
Usage: ${0##*/} [--build] [--php X.Y] <image-ref>

Run <image-ref> in the web role (FreeUnit serving PHP) and the cron role
(supercronic executing jobs), assert both work, and verify the Drupal
toolchain binaries are present.

  <image-ref>   image to test, e.g. freeunit-drupal:local-php8.4
  --build       docker build <image-ref> from the repo root before testing
  --php X.Y     PHP line to build (--build only; --php=X.Y is also accepted);
                default: parsed from the ref's 'phpX.Y' tag, else the Dockerfile
                ARG default
  -h, --help    show this help and exit
EOF
}

# shellcheck source=test/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
parse_test_args "$@"

MARKER='freeunit-drupal-smoke-ok'
CONTAINER="freeunit-drupal-smoke-$$"
CRON_CONTAINER="freeunit-drupal-cron-$$"
ANYUID_CONTAINER="freeunit-drupal-anyuid-$$"
# A uid with no passwd entry in the image: the image must run under any
# non-root uid:gid an operator passes with --user.
ANY_UID=12345
# The image user (USER of the image, the base image's distroless 'nonroot').
# Centralised here, not hardcoded in the assertions, so a base image that
# renames it only needs SMOKE_APP_USER / SMOKE_APP_UID overridden in one place.
APP_USER="${SMOKE_APP_USER:-nonroot}"
APP_UID="${SMOKE_APP_UID:-65532}"
# Write or privilege failures a missing writable path or capability leaves in
# the logs of a read-only, capability-free container.
LOG_ERROR_PATTERN='Read-only file system|Operation not permitted|Permission denied'
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$REPO_ROOT/test/fixtures"

# Assemble a /docker-entrypoint.d in a temp dir so the config is injected
# without committing generated files (only config.json is under version control).
config_dir="$(mktemp -d)"
chmod 0755 "$config_dir"

cleanup() {
    docker rm -f "$CONTAINER"      >/dev/null 2>&1 || true
    docker rm -f "$CRON_CONTAINER" >/dev/null 2>&1 || true
    docker rm -f "$ANYUID_CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$config_dir"
}
trap cleanup EXIT

# Print a failure message followed by the relevant container's logs and exit
# non-zero. Args: <message> [<container-name>]
fail_with_logs() {
    echo "FAIL: $1" >&2
    local target="${2:-$CONTAINER}"
    echo "---- $target logs ----" >&2
    docker logs "$target" >&2 || true
    exit 1
}

cp "$FIXTURES/config.json" "$config_dir/config.json"

# The hardened posture the README documents: the image user, a read-only root
# filesystem, no capabilities, no privilege escalation. /run (Unit control
# socket, pid, state) and /tmp (request bodies, PHP and job temp files) are the
# only writable paths, here tmpfs mounts owned by the process; HOME stays
# read-only. Sets HARDENED_OPTS for <uid> (gid = uid). Args: <uid>
set_hardened_opts() {
    local owner="uid=$1,gid=$1,mode=0700"
    HARDENED_OPTS=(
        --user "$1:$1"
        --read-only
        --cap-drop=ALL
        --security-opt=no-new-privileges
        --tmpfs "/run:size=16m,$owner"
        --tmpfs "/tmp:size=64m,$owner"
    )
}
set_hardened_opts "$APP_UID"

# Assert every process of <container> (tini included) runs as <uid>.
# Args: <container> [uid, default APP_UID]
assert_process_uids() {
    local target=$1 want=${2:-$APP_UID} pid uid comm seen=0
    while read -r pid uid comm; do
        seen=$((seen + 1))
        if [ "$uid" != "$want" ]; then
            fail_with_logs "process $pid ($comm) runs as uid $uid, expected $want" "$target"
        fi
    done < <(docker top "$target" -eo pid,uid,comm | tail -n +2)
    [ "$seen" -gt 1 ] || fail_with_logs "docker top listed $seen processes" "$target"
    echo "==> $target: all $seen processes run as uid $want"
}

# Wait up to 20s for the fixture crontab's /tmp/cron-marker in <container> and
# print its content. The fixture uses supercronic's 7-field (per-second)
# schedule, so the first run happens ~1s after the daemon starts; 20s is
# headroom for container startup on slow runners. Args: <container>
read_cron_marker() {
    local target=$1 _
    for _ in $(seq 1 20); do
        if ! docker inspect -f '{{.State.Running}}' "$target" 2>/dev/null | grep -q true; then
            fail_with_logs "cron container exited early" "$target"
        fi
        if docker exec "$target" test -f /tmp/cron-marker 2>/dev/null; then
            docker exec "$target" cat /tmp/cron-marker
            return 0
        fi
        sleep 1
    done
    fail_with_logs "timed out after 20s; /tmp/cron-marker was never created" "$target"
}

# Without their variables the image's /docker-entrypoint.d scripts only run:
# exactly the four launching lines, no line of their own, nothing written.
# Args: <container>
assert_image_scripts_idle() {
    local target=$1 launched own written
    launched="$(docker logs "$target" 2>&1 | grep -c 'launching /docker-entrypoint.d/[0-9][0-9]-freeunit-drupal-' || true)"
    [ "$launched" = 4 ] || fail_with_logs "expected 4 image scripts launched, got $launched" "$target"
    own="$(docker logs "$target" 2>&1 | grep 'freeunit-drupal:' || true)"
    [ -z "$own" ] || fail_with_logs "image scripts logged without being enabled: $own" "$target"
    written="$(docker exec "$target" sh -c 'ls /run/msmtprc /run/docker-entrypoint.d/freeunit-drupal.json 2>/dev/null' || true)"
    [ -z "$written" ] || fail_with_logs "image scripts wrote without being enabled: $written" "$target"
    echo "==> $target: the four image scripts ran and wrote nothing"
}

# Assert the logs of <container> carry none of LOG_ERROR_PATTERN.
# Args: <container>
assert_clean_logs() {
    local target=$1 hits
    hits="$(docker logs "$target" 2>&1 | grep -E "$LOG_ERROR_PATTERN" || true)"
    [ -z "$hits" ] || fail_with_logs "write/privilege errors in the logs: $hits" "$target"
    echo "==> $target: no write/privilege errors in the logs"
}

# Optionally build the image under test first.
build_image "$REPO_ROOT"

# ---------------------------------------------------------------------------
# (a) Web role: FreeUnit serves PHP
# ---------------------------------------------------------------------------
echo "==> [web] starting $CONTAINER from $TEST_IMAGE_REF"
docker run -d --name "$CONTAINER" \
    -p 127.0.0.1::8080 \
    "${HARDENED_OPTS[@]}" \
    -v "$FIXTURES/www:/www:ro" \
    -v "$config_dir:/docker-entrypoint.d:ro" \
    "$TEST_IMAGE_REF" >/dev/null

# Resolve the ephemeral host port docker mapped for container port 8080.
# Bind explicitly to 127.0.0.1 to avoid the '[::]:PORT' IPv6 row on dual-stack
# hosts, which the bare URL below cannot handle without bracket quoting.
if ! host_endpoint="$(docker port "$CONTAINER" 8080/tcp | grep -m1 '^127\.0\.0\.1:')"; then
    fail_with_logs "no 127.0.0.1 host mapping found for container port 8080"
fi
url="http://${host_endpoint}/"
echo "==> [web] app endpoint: $url"

echo "==> [web] waiting for the app to respond (up to 60s)"
body=""
app_responded=
for _ in $(seq 1 60); do
    if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
        fail_with_logs "container exited early"
    fi
    # --max-time bounds each probe: an accepted-but-stalled connection (e.g. a
    # wedged PHP worker) must not hang the loop past its iteration cadence.
    if body="$(curl -fsS --max-time 5 "$url" 2>/dev/null)"; then
        app_responded=1
        break
    fi
    sleep 1
done

if [ -z "$app_responded" ]; then
    fail_with_logs "timed out after 60s waiting for the app to respond at $url"
fi

echo "==> [web] response: ${body:-<empty>}"
if [[ "$body" != *"$MARKER"* ]]; then
    fail_with_logs "expected marker '$MARKER' in response body"
fi
echo "==> [web] PASS: FreeUnit served PHP (marker present)"

# Assert the served PHP version matches the line under test, so a build that
# silently fell back to a different base PHP (wrong tag, stale cache) is caught.
# The expected line comes from --php, else the ref's 'phpX.Y' tag; if neither is
# present the version cannot be known, so the assertion is skipped (not failed).
expected_php="$TEST_PHP_VER"
if [ -z "$expected_php" ] && [[ "$TEST_IMAGE_REF" =~ php([0-9]+\.[0-9]+) ]]; then
    expected_php="${BASH_REMATCH[1]}"
fi
if [ -n "$expected_php" ]; then
    # Trailing dot anchors the line so '8.4' does not spuriously match '8.40'.
    if [[ "$body" != *"php=${expected_php}."* ]]; then
        fail_with_logs "served PHP version does not match expected line $expected_php (body: $body)"
    fi
    echo "==> [web] PASS: served PHP matches expected line $expected_php"
fi

# Assert the PHP worker runs as the image user (not root) -- the web-role
# mirror of the cron check. Skipped when ext-posix is absent (index.php then
# emits no worker-user token, so the marker still proves PHP served).
case "$body" in
    *worker-user=*)
        worker_user="${body##*worker-user=}"
        worker_user="${worker_user%% *}"
        if [ "$worker_user" = "$APP_USER" ]; then
            echo "==> [web] PASS: PHP worker runs as app user '$APP_USER'"
        elif [ "$worker_user" = root ] || [ "$worker_user" = 0 ]; then
            fail_with_logs "PHP worker runs as root; expected app user '$APP_USER'"
        else
            fail_with_logs "PHP worker runs as '$worker_user'; expected app user '$APP_USER'"
        fi
        ;;
    *)
        echo "==> [web] note: ext-posix unavailable, worker-user assertion skipped"
        ;;
esac

assert_process_uids "$CONTAINER"
assert_clean_logs "$CONTAINER"

# ---------------------------------------------------------------------------
# (b) Toolchain: verify Drupal-specific binaries are available
# ---------------------------------------------------------------------------
echo "==> [toolchain] checking required binaries via docker exec"

check_bin() {
    local bin=$1
    local desc=$2
    # `command` is a shell builtin, not an executable, so it must run inside a
    # shell: `docker exec <c> command -v X` execs argv directly and fails with
    # 127. Pass the binary name as $1 to the inner sh to keep it quoting-safe.
    if ! docker exec "$CONTAINER" sh -c 'command -v "$1"' sh "$bin" >/dev/null 2>&1; then
        fail_with_logs "binary not found: $bin ($desc)"
    fi
    # Don't just check $PATH: actually run --version so a present-but-broken
    # binary (missing shared lib, segfault) fails the gate instead of passing
    # with an empty version string. Capture first, then head in-shell to avoid a
    # SIGPIPE on the producer.
    local version
    if ! version="$(docker exec "$CONTAINER" "$bin" --version 2>&1)"; then
        fail_with_logs "binary present but '$bin --version' failed: $bin ($desc)"
    fi
    echo "==> [toolchain] $bin: $(printf '%s\n' "$version" | head -n1)"
}

# composer --version exits 0 and prints its version unconditionally.
check_bin composer "PHP dependency manager"

# supercronic -version exits 0. Run command -v inside a shell (see check_bin).
if ! docker exec "$CONTAINER" sh -c 'command -v supercronic' >/dev/null 2>&1; then
    fail_with_logs "binary not found: supercronic"
fi
echo "==> [toolchain] supercronic: $(docker exec "$CONTAINER" supercronic -version 2>&1 | head -n1)"

check_bin git        "version control"

# ssh has no --version flag; `ssh -V` prints its banner to stderr and exits 0
# (ssh rejects `--version`), so check_bin's probe can't be used here.
if ! docker exec "$CONTAINER" sh -c 'command -v ssh' >/dev/null 2>&1; then
    fail_with_logs "binary not found: ssh (openssh-client, for SSH-authenticated git remotes)"
fi
echo "==> [toolchain] ssh: $(docker exec "$CONTAINER" ssh -V 2>&1 | head -n1)"

check_bin mariadb    "MariaDB client"
check_bin less       "pager for mariadb-client output"
check_bin msmtp      "SMTP sendmail drop-in"
check_bin patch      "composer-patches applies drupal.org patches with it"

# /usr/sbin/sendmail is freeunit-drupal-sendmail, which execs msmtp: running
# it proves the whole chain, not just that a link exists.
if ! sendmail_version="$(docker exec "$CONTAINER" sendmail --version 2>&1)" \
    || [[ "$sendmail_version" != *"msmtp version"* ]]; then
    fail_with_logs "sendmail --version does not reach msmtp (got: $(printf '%s\n' "$sendmail_version" | head -n1))"
fi
echo "==> [toolchain] sendmail -> freeunit-drupal-sendmail -> msmtp OK"

# unzip has no --version flag; -v prints its banner and exits 0 (the Dockerfile
# relies on the same), so check_bin's `--version` probe can't be used here.
if ! docker exec "$CONTAINER" sh -c 'command -v unzip' >/dev/null 2>&1; then
    fail_with_logs "binary not found: unzip (Composer archive extraction)"
fi
echo "==> [toolchain] unzip: $(docker exec "$CONTAINER" unzip -v 2>&1 | head -n1)"

echo "==> [toolchain] PASS: all required binaries present"

# The base dispatcher refuses (and stops the container on) a hook the process
# could rewrite: owned by a non-root user, or group/world-writable. COPY keeps
# the mode of the build context, so a checkout under umask 002 would ship 0664.
hook_stat="$(docker exec "$CONTAINER" stat -c '%U:%G %a' /docker-entrypoint-hook.d/supercronic.sh)"
case "$hook_stat" in
    "root:root "?[0145][0145]) echo "==> [hook] PASS: supercronic.sh is $hook_stat" ;;
    *) fail_with_logs "supercronic.sh must be root:root, not group/world-writable; got $hook_stat" ;;
esac

# ---------------------------------------------------------------------------
# (c) Cron role: supercronic command runs jobs as the app user
# ---------------------------------------------------------------------------
echo "==> [cron] starting $CRON_CONTAINER with command: supercronic"
# Mount the smoke-test crontab (writes /tmp/cron-marker every second) in place
# of the image's default one. Same hardened posture as the web role.
docker run -d --name "$CRON_CONTAINER" \
    "${HARDENED_OPTS[@]}" \
    -v "$FIXTURES/crontab:/etc/supercronic/crontab:ro" \
    "$TEST_IMAGE_REF" supercronic >/dev/null

echo "==> [cron] waiting for cron job to write /tmp/cron-marker (up to 20s)"
cron_marker_content="$(read_cron_marker "$CRON_CONTAINER")"
echo "==> [cron] marker content: ${cron_marker_content:-<empty>}"

# The crontab writes 'cron-ok-<username>'; verify the job ran as the configured
# app user and -- the security property under test -- crucially NOT as root.
case "$cron_marker_content" in
    *"cron-ok-${APP_USER}"*) ;;
    *cron-ok-root*)
        echo "FAIL: cron job ran as root; expected app user '$APP_USER'" >&2
        echo "---- $CRON_CONTAINER logs ----" >&2
        docker logs "$CRON_CONTAINER" >&2 || true
        exit 1 ;;
    *)
        echo "FAIL: expected cron job to run as '$APP_USER', got: $cron_marker_content" >&2
        echo "---- $CRON_CONTAINER logs ----" >&2
        docker logs "$CRON_CONTAINER" >&2 || true
        exit 1 ;;
esac
echo "==> [cron] PASS: cron job ran as app user '$APP_USER' (marker: $cron_marker_content)"

assert_process_uids "$CRON_CONTAINER"
assert_clean_logs "$CRON_CONTAINER"
assert_image_scripts_idle "$CRON_CONTAINER"

# The hook adds -no-reap (tini is PID 1 and reaps), so supercronic must not log
# its "not pid 1" reaping warning.
if docker logs "$CRON_CONTAINER" 2>&1 | grep -q 'process reaping disabled'; then
    fail_with_logs "supercronic started without -no-reap" "$CRON_CONTAINER"
fi
echo "==> [cron] PASS: supercronic runs with -no-reap"

# A trailing argument that is neither a flag nor an existing file is refused
# with a clear message instead of supercronic's usage text.
echo "==> [cron] supercronic /nonexistent-crontab must fail"
if refusal="$(docker run --rm "${HARDENED_OPTS[@]}" "$TEST_IMAGE_REF" supercronic /nonexistent-crontab 2>&1)"; then
    echo "FAIL: supercronic with a missing crontab path started" >&2
    exit 1
fi
case "$refusal" in
    *"supercronic crontab not found: /nonexistent-crontab"*) echo "==> [cron] PASS: missing crontab path refused" ;;
    *) echo "FAIL: unexpected output for a missing crontab path: $refusal" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# (d) Any uid: the cron role under a uid with no passwd entry
# ---------------------------------------------------------------------------
echo "==> [any-uid] starting $ANYUID_CONTAINER as $ANY_UID:$ANY_UID"
set_hardened_opts "$ANY_UID"
docker run -d --name "$ANYUID_CONTAINER" \
    "${HARDENED_OPTS[@]}" \
    -v "$FIXTURES/crontab:/etc/supercronic/crontab:ro" \
    "$TEST_IMAGE_REF" supercronic >/dev/null
anyuid_marker="$(read_cron_marker "$ANYUID_CONTAINER")"
# `id -un` prints the number for a uid without a passwd entry.
if [ "$anyuid_marker" != "cron-ok-$ANY_UID" ]; then
    fail_with_logs "expected marker cron-ok-$ANY_UID, got: $anyuid_marker" "$ANYUID_CONTAINER"
fi
echo "==> [any-uid] PASS: cron job ran as uid $ANY_UID"
assert_process_uids "$ANYUID_CONTAINER" "$ANY_UID"
assert_clean_logs "$ANYUID_CONTAINER"
assert_image_scripts_idle "$ANYUID_CONTAINER"

echo "PASS: $MARKER -- web, toolchain, cron role and any uid verified for $TEST_IMAGE_REF"
