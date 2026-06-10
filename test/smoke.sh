#!/usr/bin/env bash
#
# End-to-end smoke test for freeunit-drupal: optionally build, then assert:
#   (a) web role  -- Unit serves PHP through the freeunit-drupal image
#   (b) toolchain -- composer, supercronic, git, mariadb-client, patch present
#   (c) cron role -- supercronic command runs jobs as the app user
#
#   ./test/smoke.sh freeunit-drupal:trixie-php8.4         # test a prebuilt image
#   ./test/smoke.sh --build freeunit-drupal:trixie-php8.4 # build it first, then test
#   ./test/smoke.sh --build --php 8.3 freeunit-drupal:dev # build a chosen PHP line

set -euo pipefail

usage() {
    cat <<EOF
Usage: ${0##*/} [--build] [--php X.Y] <image-ref>

Run <image-ref> in the web role (Unit serving PHP) and the cron role
(supercronic executing jobs), assert both work, and verify the Drupal
toolchain binaries are present.

  <image-ref>   image to test, e.g. freeunit-drupal:trixie-php8.4
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
# App user the base image drops privileges to (its APPLICATION_USER default).
# Centralised here, not hardcoded in the cron assertion, so a base image that
# renames its app user only needs SMOKE_APP_USER overridden in one place.
APP_USER="${SMOKE_APP_USER:-unit}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$REPO_ROOT/test/fixtures"

# Assemble a /docker-entrypoint.d in a temp dir so the config is injected
# without committing generated files (only config.json is under version control).
config_dir="$(mktemp -d)"
chmod 0755 "$config_dir"

cleanup() {
    docker rm -f "$CONTAINER"      >/dev/null 2>&1 || true
    docker rm -f "$CRON_CONTAINER" >/dev/null 2>&1 || true
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

# Optionally build the image under test first.
build_image "$REPO_ROOT"

# ---------------------------------------------------------------------------
# (a) Web role: Unit serves PHP
# ---------------------------------------------------------------------------
echo "==> [web] starting $CONTAINER from $TEST_IMAGE_REF"
# Run under the hardened posture the README documents: drop all capabilities,
# keep only the two the root unitd master needs to drop workers to the app
# user/group, and forbid privilege escalation.
docker run -d --name "$CONTAINER" \
    -p 127.0.0.1::8080 \
    --cap-drop=ALL \
    --cap-add=SETUID --cap-add=SETGID \
    --security-opt=no-new-privileges \
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
echo "==> [web] PASS: Unit served PHP (marker present)"

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
check_bin mariadb    "MariaDB client"
check_bin msmtp      "SMTP sendmail drop-in"
check_bin patch      "composer-patches applies drupal.org patches with it"

# The image symlinks msmtp as /usr/sbin/sendmail so PHP's mail() works out of
# the box; assert the link resolves to the msmtp binary, not just that it exists.
if ! docker exec "$CONTAINER" sh -c '[ "$(readlink -f /usr/sbin/sendmail)" = "$(command -v msmtp)" ]'; then
    sendmail_target="$(docker exec "$CONTAINER" readlink -f /usr/sbin/sendmail 2>/dev/null || echo '<none>')"
    fail_with_logs "/usr/sbin/sendmail does not resolve to the msmtp binary (got: $sendmail_target)"
fi
echo "==> [toolchain] sendmail -> msmtp symlink OK"

# unzip has no --version flag; -v prints its banner and exits 0 (the Dockerfile
# relies on the same), so check_bin's `--version` probe can't be used here.
if ! docker exec "$CONTAINER" sh -c 'command -v unzip' >/dev/null 2>&1; then
    fail_with_logs "binary not found: unzip (Composer archive extraction)"
fi
echo "==> [toolchain] unzip: $(docker exec "$CONTAINER" unzip -v 2>&1 | head -n1)"

echo "==> [toolchain] PASS: all required binaries present"

# ---------------------------------------------------------------------------
# (c) Cron role: supercronic command runs jobs as the app user
# ---------------------------------------------------------------------------
echo "==> [cron] starting $CRON_CONTAINER with command: supercronic"
# Mount the smoke-test crontab (writes /var/tmp/cron-marker every minute) in
# place of the image's default one. supercronic runs as root until the hook
# calls exec_as_user, which needs CAP_SETUID and CAP_SETGID -- same posture as
# the web role.
docker run -d --name "$CRON_CONTAINER" \
    --cap-drop=ALL \
    --cap-add=SETUID --cap-add=SETGID \
    --security-opt=no-new-privileges \
    -v "$FIXTURES/crontab:/etc/supercronic/crontab:ro" \
    "$TEST_IMAGE_REF" supercronic >/dev/null

echo "==> [cron] waiting for cron job to write /var/tmp/cron-marker (up to 20s)"
# The fixture crontab uses supercronic's full 7-field (per-second) schedule, so
# the first run happens ~1s after the daemon starts. 20s is ample headroom for
# container startup on slow runners without the per-minute boundary wait.
cron_marker_found=
for _ in $(seq 1 20); do
    if ! docker inspect -f '{{.State.Running}}' "$CRON_CONTAINER" 2>/dev/null | grep -q true; then
        fail_with_logs "cron container exited early" "$CRON_CONTAINER"
    fi
    if docker exec "$CRON_CONTAINER" test -f /var/tmp/cron-marker 2>/dev/null; then
        cron_marker_found=1
        break
    fi
    sleep 1
done

if [ -z "$cron_marker_found" ]; then
    fail_with_logs "timed out after 20s; /var/tmp/cron-marker was never created" "$CRON_CONTAINER"
fi

cron_marker_content="$(docker exec "$CRON_CONTAINER" cat /var/tmp/cron-marker 2>/dev/null)"
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

echo "PASS: $MARKER -- web, toolchain, and cron role all verified for $TEST_IMAGE_REF"
