#!/bin/sh
#
# Runs a Drupal site image built FROM freeunit-drupal as unit and cron under
# the hardening fragment of the image (docker-compose.hardening.yml: non-root
# user, read-only rootfs, no-new-privileges, every capability dropped, tmpfs
# /run, /tmp on a volume) and checks that both roles work and write nothing
# outside their mounts. Runs on the docker host, with the rights of the docker
# socket: take it from the image, by digest, after verifying the attestation
# (README, "Hardening check").
#
#   hardening-check.sh [--compose-copy <file>] <image>
#
#   --compose-copy <file>  the site's copy of the fragment must equal the
#                          fragment of <image> byte for byte
#
# Environment:
#   FREEUNIT_DRUPAL_HARDENING_ENV_FILE       env file of the site for both roles
#                                            (after the defaults
#                                            FREEUNIT_DRUPAL_UNIT_CONFIG=1 and
#                                            FREEUNIT_DRUPAL_HEALTHCHECK_HOST)
#   FREEUNIT_DRUPAL_HARDENING_HOST           Host header of the requests
#                                            (localhost)
#   FREEUNIT_DRUPAL_HARDENING_WRITABLE_DIRS  container dirs, space-separated,
#                                            mounted as tmpfs of the run uid
#   FREEUNIT_DRUPAL_HARDENING_CRONTAB        crontab of the cron role; when set,
#                                            the check waits up to 75 s for its
#                                            first job to finish
#
# The containers run without a database in their own compose project
# (freeunit-drupal-hardening-<pid>) as the numeric USER of the image; the
# project and its volume are removed on exit. Output is TAP; the exit code is
# 1 when a test fails, 2 when a precondition does (Bail out!).

set -u

usage() {
    sed -n '11,15p' "$0" | sed 's/^# \{0,1\}//'
}

compose_copy=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --compose-copy) compose_copy=${2:-}; [ "$#" -ge 2 ] && shift; shift ;;
        --compose-copy=*) compose_copy=${1#*=}; shift ;;
        --) shift; break ;;
        -*) echo "Bail out! unknown option $1"; exit 2 ;;
        *) break ;;
    esac
done
if [ "$#" -ne 1 ]; then
    echo "Bail out! usage: hardening-check.sh [--compose-copy <file>] <image>"
    exit 2
fi
image=$1
host=${FREEUNIT_DRUPAL_HARDENING_HOST:-localhost}
crontab=${FREEUNIT_DRUPAL_HARDENING_CRONTAB:-}
writable_dirs=${FREEUNIT_DRUPAL_HARDENING_WRITABLE_DIRS:-}
env_file=${FREEUNIT_DRUPAL_HARDENING_ENV_FILE:-}
project=freeunit-drupal-hardening-$$
error_pattern='Read-only file system|Operation not permitted|Permission denied'

n=0
failures=0
ok() { n=$((n + 1)); echo "ok $n - $1"; }
fail() { n=$((n + 1)); failures=$((failures + 1)); echo "not ok $n - $1${2:+ # got: $2}"; }
bail() { echo "Bail out! $1"; exit 2; }
# Records test $1 from the exit code of the command "$3...", reporting $2 on failure.
check() {
    hc_name=$1
    hc_got=$2
    shift 2
    if "$@"; then ok "$hc_name"; else fail "$hc_name" "$hc_got"; fi
}
one_line() { printf '%s' "$1" | tr '\n' ' ' | cut -c 1-200; }

command -v docker >/dev/null 2>&1 || bail "docker not found"
docker compose version >/dev/null 2>&1 || bail "docker compose not found"
user=$(docker image inspect --format '{{.Config.User}}' "$image" 2>/dev/null) || bail "no image $image"
uid=${user%%:*}
gid=${user#*:}
case "$user" in
    *[!0-9:]* | :* | *: | *:*:* | [!0-9]* | "$uid") bail "$image has no numeric uid:gid in USER: ${user:-empty}" ;;
esac
if [ -n "$env_file" ]; then
    [ -r "$env_file" ] || bail "FREEUNIT_DRUPAL_HARDENING_ENV_FILE is not readable: $env_file"
    case "$env_file" in
        /*) ;;
        *) env_file=$(pwd)/$env_file ;;
    esac
fi

work=$(mktemp -d) || bail "mktemp failed"
hc_tmp_dir=
# A start the check expects to be refused would run forever if it is not.
hc_timeout=
compose() {
    FREEUNIT_DRUPAL_RUN_UID=$uid FREEUNIT_DRUPAL_RUN_GID=$gid \
        FREEUNIT_DRUPAL_TMP_DIR=${hc_tmp_dir:-hardening-tmp} HARDENING_IMAGE=$image \
        ${hc_timeout:+timeout "$hc_timeout"} docker compose --env-file /dev/null --project-directory "$work" \
        -f "$work/compose.yml" -p "$project" "$@"
}
cleanup() {
    if [ -f "$work/compose.yml" ]; then
        compose down -v --timeout 5 >/dev/null 2>&1
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker run --rm --network none --entrypoint cat "$image" \
    /usr/local/share/freeunit-drupal/docker-compose.hardening.yml >"$work/hardening.yml" 2>/dev/null \
    || bail "$image has no /usr/local/share/freeunit-drupal/docker-compose.hardening.yml"

if [ -n "$compose_copy" ]; then
    check "$compose_copy equals the hardening fragment of the image" \
        "$(cmp "$compose_copy" "$work/hardening.yml" 2>&1)" cmp -s "$compose_copy" "$work/hardening.yml"
fi

printf 'FREEUNIT_DRUPAL_UNIT_CONFIG=1\nFREEUNIT_DRUPAL_HEALTHCHECK_HOST=%s\n' "$host" >"$work/defaults.env"
{
    echo "x-role: &role"
    echo "  extends:"
    echo "    file: hardening.yml"
    echo "    service: hardened"
    echo "  image: \${HARDENING_IMAGE}"
    echo "  env_file:"
    echo "    - defaults.env"
    [ -z "$env_file" ] || echo "    - \"$env_file\""
    if [ -n "$writable_dirs" ]; then
        echo "  tmpfs:"
        set -f
        for hc_dir in $writable_dirs; do
            echo "    - \"$hc_dir:size=16m,uid=$uid,gid=$gid,mode=0700\""
        done
        set +f
    fi
    echo "services:"
    echo "  unit:"
    echo "    <<: *role"
    echo "    healthcheck:"
    echo "      test: [\"CMD\", \"/docker-healthcheck.sh\"]"
    echo "      interval: 2s"
    echo "      timeout: 5s"
    echo "      retries: 3"
    echo "      start_period: 60s"
    echo "      start_interval: 1s"
    echo "  cron:"
    echo "    <<: *role"
    if [ -n "$crontab" ]; then
        echo "    command: [\"supercronic\", \"$crontab\"]"
    else
        echo "    command: [\"supercronic\"]"
    fi
    echo "    healthcheck:"
    echo "      disable: true"
    echo "volumes:"
    echo "  hardening-tmp:"
} >"$work/compose.yml"

compose config -q 2>"$work/config.err" || bail "compose config: $(one_line "$(cat "$work/config.err")")"

if ! compose up -d --wait --wait-timeout 120 >/dev/null 2>&1; then
    fail "unit and cron start under the fragment and unit turns healthy"
    compose ps -a 2>&1 | sed 's/^/# /'
    compose logs --no-color --tail 40 2>&1 | sed 's/^/# /'
    echo "1..$n"
    exit 1
fi
ok "unit and cron start under the fragment and unit turns healthy"
unit=$(compose ps -q unit)
cron=$(compose ps -q cron)

in_unit() { docker exec "$unit" /bin/sh -c "$1" 2>&1; }
port=$(docker exec "$unit" /bin/sh -c 'printf %s "${FREEUNIT_DRUPAL_HEALTHCHECK_PORT:-8080}"')
# Unit's own error pages; any other answer came from PHP.
is_php_answer() {
    case "$1" in
        *'HTTP 000' | *'<title>Error '[0-9][0-9][0-9]'</title>'*) return 1 ;;
    esac
    return 0
}

check_unit() {
    hc_pass=$1
    hc_config=$(in_unit 'curl -fsS --unix-socket /var/run/control.freeunit.sock http://localhost/config')
    case "$hc_config" in
        *":$port\""*'"applications"'*) ok "$hc_pass: Unit config has the :$port listener and an application" ;;
        *) fail "$hc_pass: Unit config has the :$port listener and an application" "$(one_line "$hc_config")" ;;
    esac
    hc_code=$(in_unit "curl -s -o /dev/null -w 'HTTP %{http_code}' --max-time 20 -H 'Host: $host' http://127.0.0.1:$port/core/misc/drupal.js")
    check "$hc_pass: GET /core/misc/drupal.js is 200" "$hc_code" [ "$hc_code" = 'HTTP 200' ]
    hc_answer=$(in_unit "curl -s -w '\nHTTP %{http_code}' --max-time 20 -H 'Host: $host' http://127.0.0.1:$port/")
    check "$hc_pass: GET / is answered by PHP" "$(one_line "$hc_answer")" is_php_answer "$hc_answer"
    # shellcheck disable=SC2016 # expanded by the shell in the container
    hc_answer=$(in_unit 'f=$(mktemp) && head -c 1048576 /dev/urandom >"$f" \
        && curl -s -w "\nHTTP %{http_code}" --max-time 20 -H "Host: '"$host"'" -F "file=@$f" http://127.0.0.1:'"$port"'/; rm -f "$f"')
    check "$hc_pass: POST of a 1 MB multipart body is answered by PHP" "$(one_line "$hc_answer")" is_php_answer "$hc_answer"
}

check_unit start

smtp_host=$(docker exec "$unit" /bin/sh -c 'printf %s "${FREEUNIT_DRUPAL_SMTP_HOST:-}"')
if [ -n "$smtp_host" ]; then
    hc_pretend=$(in_unit 'freeunit-drupal-sendmail --pretend')
    case "$hc_pretend" in
        *"$smtp_host"*) ok "freeunit-drupal-sendmail reads /run/msmtprc with the SMTP host" ;;
        *) fail "freeunit-drupal-sendmail reads /run/msmtprc with the SMTP host" "$(one_line "$hc_pretend")" ;;
    esac
    hc_mode=$(in_unit 'stat -c %a /run/msmtprc')
    check "/run/msmtprc is 0600" "$hc_mode" [ "$hc_mode" = 600 ]
fi
# shellcheck disable=SC2016 # expanded by the shell in the container
hc_sendmail=$(in_unit 'XDEBUG_MODE=off php -r "echo ini_get(\"sendmail_path\");"; echo
    for f in /etc/php/*/embed/php.ini /etc/php/*/embed/conf.d/*.ini; do
        sed -n "s/^[[:space:]]*sendmail_path[[:space:]]*=[[:space:]]*//p" "$f"
    done | tail -n 1 | tr -d "\""')
hc_expected=$(printf '%s\n%s' '/usr/local/bin/freeunit-drupal-sendmail -t -i' '/usr/local/bin/freeunit-drupal-sendmail -t -i')
check "sendmail_path of cli and embed is freeunit-drupal-sendmail" "$(one_line "$hc_sendmail")" [ "$hc_sendmail" = "$hc_expected" ]

if docker restart --timeout 5 "$unit" >/dev/null 2>&1 && compose up -d --wait --wait-timeout 120 >/dev/null 2>&1; then
    ok "unit turns healthy again after docker restart"
    check_unit restart
else
    fail "unit turns healthy again after docker restart"
fi

hc_starting=$(docker logs "$cron" 2>&1 | grep -c 'starting supercronic')
check "cron logs starting supercronic" "$hc_starting" [ "$hc_starting" -ge 1 ]
if [ -n "$crontab" ]; then
    hc_job=
    hc_waited=0
    while [ "$hc_waited" -lt 75 ]; do
        hc_job=$(docker logs "$cron" 2>&1 | grep -m 1 -E 'msg="?job succeeded|error running command|msg="?job failed')
        [ -z "$hc_job" ] || break
        sleep 3
        hc_waited=$((hc_waited + 3))
    done
    check "cron finishes its first job within 75 s" "no job result" [ -n "$hc_job" ]
fi

for role in unit cron; do
    if [ "$role" = unit ]; then id=$unit; else id=$cron; fi
    hc_uids=$(docker top "$id" -eo pid,uid | awk 'NR > 1 { print $2 }' | sort -u | tr '\n' ' ')
    check "$role: every process runs as uid $uid" "$hc_uids" [ "$hc_uids" = "$uid " ]
    hc_exec_uid=$(docker exec "$id" id -u 2>&1)
    check "$role: docker exec runs as uid $uid" "$hc_exec_uid" [ "$hc_exec_uid" = "$uid" ]
    hc_hits=$(docker logs "$id" 2>&1 | grep -E "$error_pattern")
    check "$role: logs carry no write or privilege error" "$(printf '%s' "$hc_hits" | head -n 1)" [ -z "$hc_hits" ]
done

hc_timeout=60
hc_out=$(compose run --rm --no-deps --user 0:0 unit 2>&1)
hc_rc=$?
case "$hc_out" in
    *'started as root without'*) hc_refused=$hc_rc ;;
    *) hc_refused=0 ;;
esac
check "a root start with every capability dropped is refused" \
    "rc $hc_rc: $(printf '%s' "$hc_out" | tail -n 1)" [ "$hc_refused" -ne 0 ]

mkdir "$work/ro-tmp" && chmod 0555 "$work/ro-tmp"
hc_tmp_dir=$work/ro-tmp
hc_out=$(compose run --rm --no-deps unit 2>&1)
hc_rc=$?
hc_tmp_dir=
hc_timeout=
case "$hc_out" in
    *'/tmp is not writable'*) hc_refused=$hc_rc ;;
    *) hc_refused=0 ;;
esac
check "a start with a /tmp the run uid cannot write is refused" \
    "rc $hc_rc: $(printf '%s' "$hc_out" | tail -n 1)" [ "$hc_refused" -ne 0 ]

echo "1..$n"
[ "$failures" -eq 0 ]
