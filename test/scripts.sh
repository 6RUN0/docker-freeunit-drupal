#!/bin/sh
#
# Tests of the Drupal entrypoint scripts, tools and library of the image:
# rendering, routes of the built-in Unit template, flags, mail, writable dirs,
# upgrade, tmp cleanup, healthcheck, script order, a non-empty /run, a uid
# without a passwd entry, compatibility with a 0.4.0-style site script and the
# shipped hardening check. Builds two site images FROM <image>
# (test/fixtures/scripts/Dockerfile) and runs them with the flags of the smoke
# test: the image user, read-only, no capabilities, tmpfs /run and /tmp.
#
#   test/scripts.sh freeunit-drupal:local-php8.4
#
# Output is TAP; the exit code is 1 when a test fails, 2 when a precondition
# does (Bail out!). Containers, images and dirs it creates are removed on exit.

set -u

if [ "$#" -ne 1 ]; then
    echo "usage: ${0##*/} <image-ref>" >&2
    exit 2
fi
image=$1
here=$(cd "$(dirname "$0")" && pwd)
fixtures=$here/fixtures/scripts
prefix=freeunit-drupal-scripts-$$
site_image=$prefix-site
compat_image=$prefix-compat
app_uid=65532
any_uid=12345
wrapper_path='/usr/local/bin/freeunit-drupal-sendmail -t -i'

n=0
failures=0
ok() { n=$((n + 1)); echo "ok $n - $1"; }
fail() { n=$((n + 1)); failures=$((failures + 1)); echo "not ok $n - $1${2:+ # got: $2}"; }
bail() { echo "Bail out! $1"; exit 2; }
# Records test $1 from the exit code of the command "$3...", reporting $2 on failure.
check() {
    t_name=$1
    t_got=$2
    shift 2
    if "$@"; then ok "$t_name"; else fail "$t_name" "$t_got"; fi
}
# True when $1 contains $2.
has() {
    case "$1" in
        *"$2"*) return 0 ;;
    esac
    return 1
}
lacks() { ! has "$1" "$2"; }
one_line() { printf '%s' "$1" | tr '\n' ' ' | cut -c 1-300; }

containers=
run_dirs=
work=
cleanup() {
    for t_c in $containers; do
        docker rm -f "$t_c" >/dev/null 2>&1
    done
    for t_d in $run_dirs; do
        docker run --rm --user 0:0 --network none -v "$t_d:/d" --entrypoint /bin/sh "$image" \
            -c 'find /d -mindepth 1 -delete; chown "$1" /d' sh "$(id -u):$(id -g)" >/dev/null 2>&1
        rmdir "$t_d" 2>/dev/null
    done
    docker rmi -f "$site_image" "$compat_image" >/dev/null 2>&1
    [ -z "$work" ] || rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

command -v docker >/dev/null 2>&1 || bail "docker not found"
docker image inspect "$image" >/dev/null 2>&1 || bail "no image $image"
work=$(mktemp -d) || bail "mktemp failed"
for t_target in site compat; do
    docker build -q --build-arg "IMAGE=$image" --target "$t_target" -t "$prefix-$t_target" "$fixtures" \
        >"$work/build.log" 2>&1 || bail "building the $t_target fixture image: $(one_line "$(tail -n 5 "$work/build.log")")"
done
php_ver=$(docker run --rm --network none --entrypoint /bin/sh "$image" -c 'ls /etc/php' 2>/dev/null)
[ -n "$php_ver" ] || bail "no /etc/php/<version> in $image"

# Start container <name> detached with the hardened flags as <uid>; the rest
# is passed to docker run (options, then the image and its command). A
# non-empty run_volume replaces the /run tmpfs with that host dir.
run_volume=
start() {
    t_s_name=$prefix-$1
    t_s_uid=$2
    shift 2
    containers="$containers $t_s_name"
    if [ -n "$run_volume" ]; then
        set -- -v "$run_volume:/run" "$@"
    else
        set -- --tmpfs "/run:size=16m,uid=$t_s_uid,gid=$t_s_uid,mode=0700" "$@"
    fi
    docker run -d --name "$t_s_name" --user "$t_s_uid:$t_s_uid" --read-only --cap-drop=ALL \
        --security-opt=no-new-privileges --tmpfs "/tmp:size=64m,uid=$t_s_uid,gid=$t_s_uid,mode=0700" \
        "$@" >/dev/null 2>"$work/start.err"
}
# Runs a shell command in container <name>, stderr included.
in_c() { docker exec "$prefix-$1" /bin/sh -c "$2" 2>&1; }
logs() { docker logs "$prefix-$1" 2>&1; }

# Wait up to 60 s until web container <name> finished its configuration round
# and its control socket answers.
wait_web() {
    t_w=0
    while [ "$t_w" -lt 60 ]; do
        [ "$(docker inspect -f '{{.State.Running}}' "$prefix-$1" 2>/dev/null)" = true ] || return 1
        if logs "$1" | grep -q -E 'ready for start up|skipping initial configuration' \
            && in_c "$1" 'curl -fsS --max-time 2 --unix-socket /var/run/control.freeunit.sock http://localhost/config' >/dev/null; then
            return 0
        fi
        sleep 1
        t_w=$((t_w + 1))
    done
    return 1
}
# Wait up to 30 s until the logs of container <name> match the ERE <pattern>.
wait_log() {
    t_w=0
    while [ "$t_w" -lt 30 ]; do
        logs "$1" | grep -q -E "$2" && return 0
        [ "$(docker inspect -f '{{.State.Running}}' "$prefix-$1" 2>/dev/null)" = true ] || return 1
        sleep 1
        t_w=$((t_w + 1))
    done
    return 1
}
# Wait up to 30 s until <count> lines of the logs of container <name> match
# the ERE <pattern>.
wait_count() {
    t_w=0
    while [ "$t_w" -lt 30 ]; do
        [ "$(logs "$1" | grep -c -E "$2")" -ge "$3" ] && return 0
        sleep 1
        t_w=$((t_w + 1))
    done
    return 1
}
# Start web container <name> as <uid> and record whether it came up.
start_web() {
    t_sw_name=$1
    start "$@"
    if wait_web "$t_sw_name"; then
        ok "$t_sw_name: web role starts"
        return 0
    fi
    fail "$t_sw_name: web role starts" "$(one_line "$(cat "$work/start.err"; logs "$t_sw_name" | tail -n 5)")"
    return 1
}
# Start cron container <name> as <uid> and wait for supercronic.
start_cron() {
    t_sc_name=$1
    start "$@"
    if wait_log "$t_sc_name" 'starting supercronic'; then
        ok "$t_sc_name: cron role starts"
        return 0
    fi
    fail "$t_sc_name: cron role starts" "$(one_line "$(cat "$work/start.err"; logs "$t_sc_name" | tail -n 5)")"
    return 1
}
# A start that must stop in /docker-entrypoint.d/<script> with <text> in the
# log. Sets t_r_took to the seconds from start to exit.
# Args: <name> <script> <text> <docker run args...>
expect_refusal() {
    t_r_name=$1
    t_r_script=$2
    t_r_text=$3
    shift 3
    t_r_label="$t_r_name: start stops in $t_r_script with '$t_r_text'"
    t_r_start=$(date +%s)
    start "$t_r_name" "$app_uid" "$@"
    t_r_code=$(timeout 60 docker wait "$prefix-$t_r_name" 2>&1)
    t_r_rc=$?
    t_r_took=$(($(date +%s) - t_r_start))
    if [ "$t_r_rc" -ne 0 ]; then
        fail "$t_r_label" "container kept running"
        return
    fi
    t_r_logs=$(logs "$t_r_name")
    if [ "$t_r_code" != 0 ] \
        && has "$t_r_logs" "entrypoint script failed (exit " \
        && has "$t_r_logs" "): /docker-entrypoint.d/$t_r_script" \
        && has "$t_r_logs" "$t_r_text"; then
        ok "$t_r_label"
    else
        fail "$t_r_label" "exit $t_r_code: $(one_line "$(printf '%s\n' "$t_r_logs" | grep -v '^$' | tail -n 3)")"
    fi
}
# Status line of a request from inside container <name>: "<code> <body>".
http() { in_c "$1" "curl -s --max-time 10 -w ' HTTP%{http_code}' $2"; }

# --- Web role: built-in template, routes, environment, mail, healthcheck ---

if start_web web "$app_uid" \
    -e FREEUNIT_DRUPAL_UNIT_CONFIG=1 \
    -e FREEUNIT_DRUPAL_UNIT_MAX_BODY_SIZE=2097152 \
    -e FREEUNIT_DRUPAL_WRITABLE_DIRS='/tmp /run' \
    -e FREEUNIT_DRUPAL_SMTP_HOST=smtp.example.test \
    -e FREEUNIT_DRUPAL_SMTP_PORT=2525 \
    -e FREEUNIT_DRUPAL_SMTP_FROM=site@example.test \
    -e FREEUNIT_DRUPAL_SMTP_HOTS=typo \
    -e FREEUNIT_DRUPAL_UPGRADE=1 \
    -e FREEUNIT_DRUPAL_HEALTHCHECK_HOST=localhost \
    -e FREEUNIT_DRUPAL_HEALTHCHECK_PATH=/health \
    -e FD_STUB_BOOTSTRAP=Successful \
    -e FD_PROBE=visible \
    "$site_image"; then
    t_config=$(in_c web 'curl -fsS --unix-socket /var/run/control.freeunit.sock http://localhost/config')
    if has "$t_config" '"*:8080"' && has "$t_config" '"drupal"' && has "$t_config" '"/www/web/"'; then
        ok "web: built-in template applied (*:8080, application drupal, root /www/web/)"
    else
        fail "web: built-in template applied (*:8080, application drupal, root /www/web/)" "$(one_line "$t_config")"
    fi
    t_files=$(in_c web 'ls /run/docker-entrypoint.d')
    check "web: generated dir holds freeunit-drupal.json only" "$(one_line "$t_files")" [ "$t_files" = freeunit-drupal.json ]

    t_order=$(logs web | sed -n 's|.*launching /docker-entrypoint.d/||p' | tr '\n' ' ')
    t_expected='000_site.sh 10-freeunit-drupal-writable-dirs.sh 20-freeunit-drupal-msmtp.sh 30-freeunit-drupal-unit-config.sh 500_site.sh 90-freeunit-drupal-upgrade.sh 999_site.sh '
    check "web: scripts run in byte order 000_ 10- 20- 30- 500_ 90- 999_" "$t_order" [ "$t_order" = "$t_expected" ]
    t_logs=$(logs web)
    check "web: site script sources lib.sh and logs through it" "no such line" has "$t_logs" 'freeunit-drupal: site script 500 sourced lib.sh'
    check "web: unknown FREEUNIT_DRUPAL_SMTP_HOTS is warned about" "no warning" \
        has "$t_logs" 'unknown variable FREEUNIT_DRUPAL_SMTP_HOTS (typo?)'
    check "web: known variables are not warned about" "$(one_line "$(printf '%s\n' "$t_logs" | grep 'unknown variable' | grep -v SMTP_HOTS)")" \
        [ "$(printf '%s\n' "$t_logs" | grep 'unknown variable' | grep -c -v SMTP_HOTS)" = 0 ]
    check "web: upgrade in the web role is warned about" "no warning" \
        has "$t_logs" 'upgrade runs in the web role; enable it in one role only'

    t_r=$(http web 127.0.0.1:8080/node/1)
    check "web: /node/1 is answered by index.php" "$t_r" has "$t_r" 'fd-index uri=/node/1'
    t_r=$(http web 127.0.0.1:8080/index.php)
    check "web: /index.php is executed, not served as source" "$t_r" has "$t_r" 'fd-index uri=/index.php'
    for t_path in /other.php /sites/default/files/probe.php /sites/default/settings.php /vendor/autoload.php \
        /core/install.php /core/authorize.php /core/rebuild.php /update.php /update.php/selection; do
        t_r=$(http web "127.0.0.1:8080$t_path")
        if has "$t_r" HTTP404 && lacks "$t_r" EXECUTED && lacks "$t_r" fd-index; then
            ok "web: $t_path is 404 and not executed"
        else
            fail "web: $t_path is 404 and not executed" "$(one_line "$t_r")"
        fi
    done
    for t_path in /composer.json /.htaccess /core/misc/drupal.js.orig /dump.sql /backup.mysql \
        /sites/default/files/.htaccess /sites/default/files/x.yml /sites/default/files/x.sql \
        /sites/default/files/config_abc/sync/system.site.yml /sites/default/files/config_abc/README.txt; do
        t_r=$(http web "127.0.0.1:8080$t_path")
        if has "$t_r" HTTP404 && lacks "$t_r" 'DROP TABLE' && lacks "$t_r" 'Deny from' \
            && lacks "$t_r" 'secret' && lacks "$t_r" 'key: value' && lacks "$t_r" readme; then
            ok "web: $t_path is 404"
        else
            fail "web: $t_path is 404" "$(one_line "$t_r")"
        fi
    done
    for t_path in /blog/why-postgresql /tags/mysql /.well-known/missing; do
        t_r=$(http web "127.0.0.1:8080$t_path")
        check "web: $t_path reaches index.php" "$(one_line "$t_r")" has "$t_r" "fd-index uri=$t_path"
    done
    for t_pair in '/sites/default/files/a.txt attachment' '/sites/default/files/b.csv 1,2' \
        '/sites/default/files/c.json "export"' '/.well-known/security.txt Contact:'; do
        t_path=${t_pair%% *}
        t_want=${t_pair#* }
        t_r=$(http web "127.0.0.1:8080$t_path")
        if has "$t_r" HTTP200 && has "$t_r" "$t_want"; then
            ok "web: static $t_path is served"
        else
            fail "web: static $t_path is served" "$(one_line "$t_r")"
        fi
    done
    t_r=$(http web 127.0.0.1:8080/core/misc/drupal.js)
    check "web: static /core/misc/drupal.js is 200" "$(one_line "$t_r")" has "$t_r" HTTP200
    # shellcheck disable=SC2016 # expanded by the shell in the container
    t_r=$(in_c web 'head -c 3145728 /dev/zero >/tmp/big && curl -s -o /dev/null -w "%{http_code}" --data-binary @/tmp/big -H "Content-Type: application/octet-stream" 127.0.0.1:8080/; rm -f /tmp/big')
    check "web: POST of 3 MB over max_body_size 2 MB is 413" "$t_r" [ "$t_r" = 413 ]
    # shellcheck disable=SC2016 # expanded by the shell in the container
    t_r=$(in_c web 'head -c 1048576 /dev/zero >/tmp/mid && curl -s --data-binary @/tmp/mid -H "Content-Type: application/octet-stream" 127.0.0.1:8080/; rm -f /tmp/mid')
    check "web: POST of 1 MB reaches PHP" "$(one_line "$t_r")" has "$t_r" 'body=1048576'

    t_r=$(http web 127.0.0.1:8080/)
    check "web: getenv() in the worker sees the container environment" "$(one_line "$t_r")" has "$t_r" "env='visible'"
    check "web: sendmail_path of embed is the wrapper" "$(one_line "$t_r")" has "$t_r" "sendmail=$wrapper_path body"
    t_r=$(in_c web 'php -r "echo ini_get(\"sendmail_path\");"')
    check "web: sendmail_path of cli is the wrapper" "$t_r" [ "$t_r" = "$wrapper_path" ]
    t_r=$(in_c web 'readlink -f /usr/sbin/sendmail')
    check "web: /usr/sbin/sendmail is the wrapper" "$t_r" [ "$t_r" = /usr/local/bin/freeunit-drupal-sendmail ]

    t_r=$(in_c web 'stat -c "%a %u" /run/msmtprc; head -n 1 /run/msmtprc')
    check "web: /run/msmtprc is 0600, owned by $app_uid, first line # freeunit-drupal" "$(one_line "$t_r")" \
        [ "$t_r" = "600 $app_uid
# freeunit-drupal" ]
    t_r=$(in_c web 'freeunit-drupal-sendmail --pretend')
    if has "$t_r" smtp.example.test && has "$t_r" 2525; then
        ok "web: freeunit-drupal-sendmail --pretend reads host and port of /run/msmtprc"
    else
        fail "web: freeunit-drupal-sendmail --pretend reads host and port of /run/msmtprc" "$(one_line "$t_r")"
    fi
    for t_opt in '-C /x' '--file=/x' '-X /x' '--logfile=/x' '--passwordeval=id' \
        '-tC/x' '--fil=/x' '-iX/x' '--host=x' '-ti' '-f'; do
        t_r=$(in_c web "freeunit-drupal-sendmail -t $t_opt </dev/null; echo rc=\$?")
        check "web: freeunit-drupal-sendmail refuses $t_opt with exit 64" "$(one_line "$t_r")" has "$t_r" 'rc=64'
    done

    t_r=$(in_c web 'cat /tmp/drush.log')
    check "web: upgrade runs updb in the web role too" "$(one_line "$t_r")" \
        has "$t_r" "drush --root=/www/web --no-interaction updb --yes"

    t_r=$(in_c web 'freeunit-drupal-healthcheck; echo rc=$?')
    check "healthcheck: X-Forwarded-Proto https by default, 500 otherwise: exit 0" "$(one_line "$t_r")" [ "$t_r" = rc=0 ]
    t_r=$(in_c web 'FREEUNIT_DRUPAL_HEALTHCHECK_PROTO=http freeunit-drupal-healthcheck; echo rc=$?')
    check "healthcheck: _PROTO=http gets the 500: exit non-zero" "$(one_line "$t_r")" lacks "$t_r" rc=0
    t_r=$(in_c web 'FREEUNIT_DRUPAL_HEALTHCHECK_PATH=/node/1 freeunit-drupal-healthcheck; echo rc=$?')
    check "healthcheck: a 200 page: exit 0" "$(one_line "$t_r")" [ "$t_r" = rc=0 ]
    # shellcheck disable=SC2016 # expanded by the shell in the container
    t_r=$(in_c web 's=$(date +%s); FREEUNIT_DRUPAL_HEALTHCHECK_PATH=/slow FREEUNIT_DRUPAL_HEALTHCHECK_TIMEOUT=1 freeunit-drupal-healthcheck >/dev/null 2>&1; r=$?; echo "rc=$r took=$(($(date +%s) - s))"')
    t_took=${t_r##*took=}
    if lacks "$t_r" rc=0 && [ "${t_took:-9}" -le 3 ] 2>/dev/null; then
        ok "healthcheck: _TIMEOUT=1 on a 5 s page fails within 3 s"
    else
        fail "healthcheck: _TIMEOUT=1 on a 5 s page fails within 3 s" "$t_r"
    fi
    t_r=$(in_c web 'FREEUNIT_DRUPAL_HEALTHCHECK_PORT=8099 freeunit-drupal-healthcheck >/dev/null 2>&1; echo rc=$?')
    check "healthcheck: a closed port: exit non-zero" "$t_r" lacks "$t_r" rc=0
    t_r=$(in_c web 'env -u FREEUNIT_DRUPAL_HEALTHCHECK_HOST freeunit-drupal-healthcheck; echo rc=$?')
    if has "$t_r" 'FREEUNIT_DRUPAL_HEALTHCHECK_HOST is required' && lacks "$t_r" rc=0; then
        ok "healthcheck: no _HOST: refused with the name"
    else
        fail "healthcheck: no _HOST: refused with the name" "$(one_line "$t_r")"
    fi

    # shellcheck disable=SC2016 # expanded by the shell in the container
    t_r=$(in_c web '
        now=$(date +%s)
        touch -d "@$((now - 3 * 86400))" /run/old-target
        touch /tmp/fresh; touch -d "@$((now - 30 * 3600))" /tmp/thirty-hours
        touch -d "@$((now - 3 * 86400))" /tmp/three-days
        mkdir /tmp/old-empty /tmp/fresh-empty; touch -d "@$((now - 3 * 86400))" /tmp/old-empty
        ln -s /run/old-target /tmp/link; touch -h -d "@$((now - 3 * 86400))" /tmp/link
        freeunit-drupal-tmp-cleanup 1; echo rc=$?
        for f in /tmp/fresh /tmp/thirty-hours /tmp/three-days /tmp/old-empty /tmp/fresh-empty /tmp/link /run/old-target; do
            if [ -e "$f" ] || [ -L "$f" ]; then echo "kept $f"; else echo "gone $f"; fi
        done')
    t_expected='rc=0
kept /tmp/fresh
kept /tmp/thirty-hours
gone /tmp/three-days
gone /tmp/old-empty
kept /tmp/fresh-empty
kept /tmp/link
kept /run/old-target'
    check "tmp-cleanup 1: 3-day file and old empty dir gone; fresh, 30 h, fresh dir, symlink and its target kept" \
        "$(one_line "$t_r")" [ "$t_r" = "$t_expected" ]
    t_r=$(in_c web 'freeunit-drupal-tmp-cleanup abc; echo rc=$?')
    if has "$t_r" "days must be a whole number" && lacks "$t_r" rc=0; then
        ok "tmp-cleanup abc: refused"
    else
        fail "tmp-cleanup abc: refused" "$(one_line "$t_r")"
    fi
fi

# --- Web role: listener, custom template, no mail configuration ---

if start_web listen "$app_uid" -e FREEUNIT_DRUPAL_UNIT_CONFIG=1 -e 'FREEUNIT_DRUPAL_UNIT_LISTEN=*:8081' \
    -v "$fixtures/etc-msmtprc:/etc/msmtprc:ro" "$site_image"; then
    t_r=$(http listen 127.0.0.1:8081/node/1)
    check "listen: _UNIT_LISTEN=*:8081 answers on 8081" "$(one_line "$t_r")" has "$t_r" 'fd-index'
    t_r=$(http listen 127.0.0.1:8080/node/1)
    check "listen: 8080 is closed" "$(one_line "$t_r")" has "$t_r" HTTP000
    t_r=$(in_c listen 'test -e /run/msmtprc && echo present || echo absent')
    check "listen: without _SMTP_HOST there is no /run/msmtprc" "$t_r" [ "$t_r" = absent ]
    t_r=$(in_c listen 'freeunit-drupal-sendmail --pretend')
    check "listen: the wrapper falls back to /etc/msmtprc" "$(one_line "$t_r")" has "$t_r" nonexistent.invalid
    t_r=$(in_c listen 'printf "To: to@example.test\nSubject: s\n\nb\n" | freeunit-drupal-sendmail -f a@example.test -t -i; echo rc=$?')
    if has "$t_r" 'cannot locate host nonexistent.invalid' && lacks "$t_r" rc=0 && lacks "$t_r" rc=75 && lacks "$t_r" rc=64; then
        ok "listen: -f <addr> -t -i reach msmtp, which fails on the relay"
    else
        fail "listen: -f <addr> -t -i reach msmtp, which fails on the relay" "$(one_line "$t_r")"
    fi
    t_r=$(in_c listen 'printf "b\n" | freeunit-drupal-sendmail -fa@example.test -i -- to@example.test -C/x; echo rc=$?')
    if has "$t_r" 'cannot locate host nonexistent.invalid' && lacks "$t_r" rc=64; then
        ok "listen: arguments after -- are recipients, not options"
    else
        fail "listen: arguments after -- are recipients, not options" "$(one_line "$t_r")"
    fi
fi

if start_web custom "$app_uid" -e FREEUNIT_DRUPAL_UNIT_CONFIG=1 \
    -e FREEUNIT_DRUPAL_UNIT_TEMPLATE=/fixtures/templates/custom.json.template \
    -e SITE_X=x1 -e 'SITE_A=%%SITE_B%%' -e SITE_B=b2 -e SITE_EMPTY= "$site_image"; then
    t_config=$(in_c custom 'curl -fsS --unix-socket /var/run/control.freeunit.sock http://localhost/config/applications/custom')
    t_compact=$(printf '%s' "$t_config" | tr -d ' \n')
    for t_want in '"max":8' '"X":"x1"' '"TWICE":"x1-x1"' '"AB":"%%SITE_B%%b2"' '"EMPTY":""' '"PERCENT":"100%%sure"'; do
        check "custom: rendered $t_want" "$(one_line "$t_compact")" has "$t_compact" "$t_want"
    done
fi

# --- Refusals ---

expect_refusal flag-upgrade 90-freeunit-drupal-upgrade.sh "FREEUNIT_DRUPAL_UPGRADE must be empty, 0 or 1, got 'yes'" \
    -e FREEUNIT_DRUPAL_UPGRADE=yes "$site_image" supercronic
expect_refusal flag-unit 30-freeunit-drupal-unit-config.sh "FREEUNIT_DRUPAL_UNIT_CONFIG must be empty, 0 or 1, got 'true'" \
    -e FREEUNIT_DRUPAL_UNIT_CONFIG=true "$site_image" supercronic
expect_refusal undefined 30-freeunit-drupal-unit-config.sh 'undefined variable SITE_UNSET_ONE; undefined variable SITE_UNSET_TWO' \
    -e FREEUNIT_DRUPAL_UNIT_CONFIG=1 -e FREEUNIT_DRUPAL_UNIT_TEMPLATE=/fixtures/templates/undefined.json.template \
    "$site_image" supercronic
expect_refusal newline 30-freeunit-drupal-unit-config.sh 'newline in the value of SITE_X' \
    -e FREEUNIT_DRUPAL_UNIT_CONFIG=1 -e FREEUNIT_DRUPAL_UNIT_TEMPLATE=/fixtures/templates/custom.json.template \
    -e "SITE_X=a
b" -e SITE_A= -e SITE_B= -e SITE_EMPTY= "$site_image" supercronic
expect_refusal quote-builtin 30-freeunit-drupal-unit-config.sh \
    'cannot render /usr/local/share/freeunit-drupal/unit.json.template into /run/docker-entrypoint.d/freeunit-drupal.json: the value of FREEUNIT_DRUPAL_PHP_TIMEZONE has a quote' \
    -e FREEUNIT_DRUPAL_UNIT_CONFIG=1 -e 'FREEUNIT_DRUPAL_PHP_TIMEZONE=UTC"' "$site_image"
expect_refusal backslash-custom 30-freeunit-drupal-unit-config.sh \
    'cannot render /fixtures/templates/custom.json.template into /run/docker-entrypoint.d/freeunit-drupal.json: the value of SITE_X has a quote, a backslash' \
    -e FREEUNIT_DRUPAL_UNIT_CONFIG=1 -e FREEUNIT_DRUPAL_UNIT_TEMPLATE=/fixtures/templates/custom.json.template \
    -e 'SITE_X=a\b' -e SITE_A= -e SITE_B= -e SITE_EMPTY= "$site_image" supercronic
expect_refusal invalid-json 30-freeunit-drupal-unit-config.sh 'is not valid JSON' \
    -e FREEUNIT_DRUPAL_UNIT_CONFIG=1 -e FREEUNIT_DRUPAL_UNIT_PROCESSES_MAX=eight "$site_image" supercronic
expect_refusal smtp-from 20-freeunit-drupal-msmtp.sh 'FREEUNIT_DRUPAL_SMTP_FROM is required' \
    -e FREEUNIT_DRUPAL_SMTP_HOST=smtp.example.test "$site_image" supercronic
expect_refusal smtp-tls 20-freeunit-drupal-msmtp.sh "FREEUNIT_DRUPAL_SMTP_TLS must be on or off, got 'yes'" \
    -e FREEUNIT_DRUPAL_SMTP_HOST=smtp.example.test -e FREEUNIT_DRUPAL_SMTP_FROM=a@example.test \
    -e FREEUNIT_DRUPAL_SMTP_TLS=yes "$site_image" supercronic
expect_refusal smtp-auth-plain 20-freeunit-drupal-msmtp.sh 'FREEUNIT_DRUPAL_SMTP_AUTH=on needs FREEUNIT_DRUPAL_SMTP_TLS=on' \
    -e FREEUNIT_DRUPAL_SMTP_HOST=smtp.example.test -e FREEUNIT_DRUPAL_SMTP_FROM=a@example.test \
    -e FREEUNIT_DRUPAL_SMTP_AUTH=on -e FREEUNIT_DRUPAL_SMTP_USER=u \
    -e FREEUNIT_DRUPAL_SMTP_PASSWORD_FILE=/fixtures/smtp_password "$site_image" supercronic
expect_refusal smtp-relative 20-freeunit-drupal-msmtp.sh 'FREEUNIT_DRUPAL_SMTP_PASSWORD_FILE must be an absolute path' \
    -e FREEUNIT_DRUPAL_SMTP_HOST=smtp.example.test -e FREEUNIT_DRUPAL_SMTP_FROM=a@example.test \
    -e FREEUNIT_DRUPAL_SMTP_AUTH=on -e FREEUNIT_DRUPAL_SMTP_TLS=on -e FREEUNIT_DRUPAL_SMTP_USER=u \
    -e FREEUNIT_DRUPAL_SMTP_PASSWORD_FILE=fixtures/smtp_password "$site_image" supercronic
expect_refusal smtp-quote 20-freeunit-drupal-msmtp.sh 'FREEUNIT_DRUPAL_SMTP_PASSWORD_FILE must not contain a quote' \
    -e FREEUNIT_DRUPAL_SMTP_HOST=smtp.example.test -e FREEUNIT_DRUPAL_SMTP_FROM=a@example.test \
    -e FREEUNIT_DRUPAL_SMTP_AUTH=on -e FREEUNIT_DRUPAL_SMTP_TLS=on -e FREEUNIT_DRUPAL_SMTP_USER=u \
    -e "FREEUNIT_DRUPAL_SMTP_PASSWORD_FILE=/fixtures/it's" "$site_image" supercronic
expect_refusal smtp-dquote 20-freeunit-drupal-msmtp.sh 'FREEUNIT_DRUPAL_SMTP_PASSWORD_FILE must not contain a quote, a backslash or a newline' \
    -e FREEUNIT_DRUPAL_SMTP_HOST=smtp.example.test -e FREEUNIT_DRUPAL_SMTP_FROM=a@example.test \
    -e FREEUNIT_DRUPAL_SMTP_AUTH=on -e FREEUNIT_DRUPAL_SMTP_TLS=on -e FREEUNIT_DRUPAL_SMTP_USER=u \
    -e 'FREEUNIT_DRUPAL_SMTP_PASSWORD_FILE=/fixtures/a"b' "$site_image" supercronic
for t_role in web cron; do
    if [ "$t_role" = web ]; then set -- "$site_image"; else set -- "$site_image" supercronic; fi
    expect_refusal "dirs-$t_role" 10-freeunit-drupal-writable-dirs.sh \
        "/www/web/sites/default/files is not a directory writable for uid $app_uid:$app_uid" \
        -e FREEUNIT_DRUPAL_WRITABLE_DIRS='/tmp web/sites/default/files' "$@"
done
expect_refusal db-wait 90-freeunit-drupal-upgrade.sh \
    'database not reachable after 4 s: stub: SQLSTATE[HY000] [2002] Connection refused' \
    -e FREEUNIT_DRUPAL_UPGRADE=1 -e FREEUNIT_DRUPAL_UPGRADE_DB_WAIT=4 -e FD_STUB_SQL=fail "$site_image" supercronic
expect_refusal db-hang 90-freeunit-drupal-upgrade.sh 'database not reachable after 4 s: drush sql:query got no answer within' \
    -e FREEUNIT_DRUPAL_UPGRADE=1 -e FREEUNIT_DRUPAL_UPGRADE_DB_WAIT=4 -e FD_STUB_SQL=hang "$site_image" supercronic
check "db-hang: a probe that hangs 30 s still stops the start within 12 s of a 4 s wait" "took $t_r_took s" \
    [ "$t_r_took" -le 12 ]
expect_refusal updb-fails 90-freeunit-drupal-upgrade.sh 'drush updb --yes failed' \
    -e FREEUNIT_DRUPAL_UPGRADE=1 -e FD_STUB_BOOTSTRAP=Successful -e FD_STUB_FAIL=updb "$site_image" supercronic

# Every documented variable at a neutral value: none is reported unknown.
set --
for t_var in PROJECT_DIR DOCROOT WRITABLE_DIRS UNIT_TEMPLATE UNIT_LISTEN UNIT_MAX_BODY_SIZE \
    UNIT_PROCESSES_MAX UNIT_PROCESSES_SPARE UNIT_PROCESS_IDLE_TIMEOUT UNIT_LIMITS_TIMEOUT \
    UNIT_LIMITS_REQUESTS PHP_MEMORY_LIMIT PHP_MAX_EXECUTION_TIME PHP_POST_MAX_SIZE \
    PHP_UPLOAD_MAX_FILESIZE PHP_TIMEZONE SMTP_HOST SMTP_PORT SMTP_FROM SMTP_TLS SMTP_AUTH \
    SMTP_USER SMTP_PASSWORD_FILE MSMTP_TEMPLATE UPGRADE_DB_WAIT HEALTHCHECK_HOST \
    HEALTHCHECK_PORT HEALTHCHECK_PATH HEALTHCHECK_PROTO HEALTHCHECK_TIMEOUT RUN_UID RUN_GID \
    TMP_DIR HARDENING_CRONTAB HARDENING_WRITABLE_DIRS HARDENING_HOST HARDENING_ENV_FILE; do
    set -- "$@" -e "FREEUNIT_DRUPAL_$t_var="
done
if start_cron known "$app_uid" "$@" -e FREEUNIT_DRUPAL_UNIT_CONFIG=0 -e FREEUNIT_DRUPAL_UPGRADE=0 \
    -e FREEUNIT_DRUPAL_PHP_APC_SHM_SIZE=64M "$site_image" supercronic; then
    t_r=$(logs known | grep 'unknown variable')
    if [ "$(printf '%s\n' "$t_r" | grep -c .)" = 1 ] \
        && has "$t_r" 'unknown variable FREEUNIT_DRUPAL_PHP_APC_SHM_SIZE (typo?)'; then
        ok "known: every documented FREEUNIT_DRUPAL_* name is known, the removed APC_SHM_SIZE is not"
    else
        fail "known: every documented FREEUNIT_DRUPAL_* name is known, the removed APC_SHM_SIZE is not" "$(one_line "$t_r")"
    fi
fi

# --- Healthcheck during a long configuration round ---

if start "round" "$app_uid" -e FREEUNIT_DRUPAL_UNIT_CONFIG=1 -e FREEUNIT_DRUPAL_UPGRADE=1 \
    -e FREEUNIT_DRUPAL_UPGRADE_DB_WAIT=40 -e FD_STUB_SQL=hang -e FREEUNIT_DRUPAL_HEALTHCHECK_HOST=localhost \
    "$site_image" && wait_log round 'waiting up to 40 s for the database'; then
    t_r=$(in_c round 'freeunit-drupal-healthcheck >/dev/null 2>&1; echo site=$?; /docker-healthcheck.sh >/dev/null 2>&1; echo image=$?')
    check "round: freeunit-drupal-healthcheck is unhealthy while the round waits for the database" "$(one_line "$t_r")" \
        has "$t_r" 'site=1'
    check "round: the image HEALTHCHECK (control socket) answers during the round, as documented" "$(one_line "$t_r")" \
        has "$t_r" 'image=0'
else
    fail "round: web role enters the database wait of the round" "$(one_line "$(logs round | tail -n 3)")"
fi
docker rm -f "$prefix-round" >/dev/null 2>&1

# --- Cron role: upgrade, authenticated mail ---

if start_cron upgrade "$app_uid" -e FREEUNIT_DRUPAL_UPGRADE=1 -e FD_STUB_BOOTSTRAP=Successful \
    -e DRUSH_OPTIONS_URI=https://site.example.test "$site_image" supercronic; then
    t_r=$(in_c upgrade 'grep -v -e " sql:query " -e " status " /tmp/drush.log')
    t_expected='drush --root=/www/web --no-interaction cr uri=https://site.example.test
drush --root=/www/web --no-interaction updb --yes uri=https://site.example.test
drush --root=/www/web --no-interaction cr uri=https://site.example.test'
    check "upgrade: exactly cr, updb --yes, cr with --root, --no-interaction and DRUSH_OPTIONS_URI" \
        "$(one_line "$t_r")" [ "$t_r" = "$t_expected" ]
    t_order=$(logs upgrade | sed -n 's|.*launching /docker-entrypoint.d/||p' | tr '\n' ' ')
    t_expected='000_site.sh 10-freeunit-drupal-writable-dirs.sh 20-freeunit-drupal-msmtp.sh 30-freeunit-drupal-unit-config.sh 500_site.sh 90-freeunit-drupal-upgrade.sh 999_site.sh '
    check "upgrade: cron runs the scripts in the same order" "$t_order" [ "$t_order" = "$t_expected" ]
    t_r=$(logs upgrade)
    check "upgrade: no web-role warning in the cron role" "warned" lacks "$t_r" 'upgrade runs in the web role'
fi

if start_cron not-installed "$app_uid" -e FREEUNIT_DRUPAL_UPGRADE=1 "$site_image" supercronic; then
    t_r=$(logs not-installed)
    check "not-installed: notice and the start goes on" "no notice" has "$t_r" 'Drupal not installed, skipping upgrade'
    t_r=$(in_c not-installed 'grep -c -e " cr " -e " updb " /tmp/drush.log')
    check "not-installed: no cr or updb" "$t_r" [ "$t_r" = 0 ]
fi

if start_cron smtp-auth "$app_uid" -e FREEUNIT_DRUPAL_SMTP_HOST=smtp.example.test \
    -e FREEUNIT_DRUPAL_SMTP_FROM=a@example.test -e FREEUNIT_DRUPAL_SMTP_PORT=587 \
    -e FREEUNIT_DRUPAL_SMTP_TLS=on -e FREEUNIT_DRUPAL_SMTP_AUTH=on -e FREEUNIT_DRUPAL_SMTP_USER=mailer \
    -e FREEUNIT_DRUPAL_SMTP_PASSWORD_FILE=/fixtures/smtp_password "$site_image" supercronic; then
    t_r=$(in_c smtp-auth 'cat /run/msmtprc')
    check "smtp-auth: passwordeval reads the password file" "$(one_line "$t_r")" \
        has "$t_r" "passwordeval \"cat '/fixtures/smtp_password'\""
    check "smtp-auth: tls on with the system trust" "$(one_line "$t_r")" has "$t_r" 'tls_trust_file system'
    t_secret=$(cat "$fixtures/smtp_password")
    check "smtp-auth: the password is not in /run/msmtprc" "found" lacks "$t_r" "$t_secret"
    t_r=$(in_c smtp-auth 'freeunit-drupal-sendmail --pretend')
    check "smtp-auth: msmtp accepts the rendered file" "$(one_line "$t_r")" has "$t_r" smtp.example.test
    t_r=$(logs smtp-auth)
    check "smtp-auth: the password is not in docker logs" "found" lacks "$t_r" "$t_secret"
fi

if start_cron smtp-template "$app_uid" -e FREEUNIT_DRUPAL_SMTP_HOST=smtp.example.test \
    -e FREEUNIT_DRUPAL_SMTP_FROM=a@example.test -e SITE_MAIL_FROM=site@example.test \
    -e FREEUNIT_DRUPAL_MSMTP_TEMPLATE=/fixtures/templates/msmtprc.template "$site_image" supercronic; then
    t_r=$(in_c smtp-template 'head -n 1 /run/msmtprc; grep "^from " /run/msmtprc')
    check "smtp-template: own template rendered after the marker line" "$(one_line "$t_r")" \
        [ "$t_r" = "# freeunit-drupal
from site@example.test" ]
fi

# --- A non-empty /run: restarts ---

t_run=$(mktemp -d) || bail "mktemp failed"
run_dirs="$run_dirs $t_run"
docker run --rm --user 0:0 --network none -v "$t_run:/d" --entrypoint chown "$image" "$app_uid:$app_uid" /d \
    >/dev/null 2>&1 || bail "cannot hand $t_run to $app_uid"
run_volume=$t_run
if start_web persist "$app_uid" -e FREEUNIT_DRUPAL_UNIT_CONFIG=1 -e FREEUNIT_DRUPAL_SMTP_HOST=smtp.example.test \
    -e FREEUNIT_DRUPAL_SMTP_FROM=a@example.test "$site_image"; then
    t_before=$(in_c persist 'sha256sum /run/msmtprc; stat -c %Y /run/msmtprc')
    if docker restart --timeout 5 "$prefix-persist" >/dev/null 2>&1 && wait_web persist; then
        ok "persist: web restarts on a non-empty /run"
        t_r=$(logs persist)
        check "persist: second start skips the configuration round" "no such line" \
            has "$t_r" 'is not empty, skipping initial configuration'
        t_r=$(http persist 127.0.0.1:8080/node/1)
        check "persist: same listener after the restart" "$(one_line "$t_r")" has "$t_r" fd-index
        t_after=$(in_c persist 'sha256sum /run/msmtprc; stat -c %Y /run/msmtprc')
        check "persist: /run/msmtprc unchanged" "$(one_line "$t_after")" [ "$t_before" = "$t_after" ]
    else
        fail "persist: web restarts on a non-empty /run" "$(one_line "$(logs persist | tail -n 5)")"
    fi
fi
docker rm -f "$prefix-persist" >/dev/null 2>&1
docker run --rm --user 0:0 --network none -v "$t_run:/d" --entrypoint find "$image" /d -mindepth 1 -delete >/dev/null 2>&1
if start_cron persist-cron "$app_uid" -e FREEUNIT_DRUPAL_UNIT_CONFIG=1 -e FREEUNIT_DRUPAL_SMTP_HOST=smtp.example.test \
    -e FREEUNIT_DRUPAL_SMTP_FROM=a@example.test "$site_image" supercronic; then
    if docker restart --timeout 5 "$prefix-persist-cron" >/dev/null 2>&1 \
        && wait_count persist-cron 'starting supercronic' 2; then
        ok "persist-cron: cron starts twice on the same /run"
    else
        fail "persist-cron: cron starts twice on the same /run" "$(one_line "$(logs persist-cron | tail -n 5)")"
    fi
    t_r=$(logs persist-cron)
    check "persist-cron: no 'written by an earlier script' from 20- or 30-" "$(one_line "$(printf '%s\n' "$t_r" | grep 'earlier script')")" \
        lacks "$t_r" 'written by an earlier script'
fi
run_volume=

# --- A uid without a passwd entry, every opt-in ---

for t_role in web cron; do
    if [ "$t_role" = web ]; then t_fn=start_web; set -- "$site_image"; else t_fn=start_cron; set -- "$site_image" supercronic; fi
    if "$t_fn" "anyuid-$t_role" "$any_uid" -e FREEUNIT_DRUPAL_UNIT_CONFIG=1 -e FREEUNIT_DRUPAL_WRITABLE_DIRS=/tmp \
        -e FREEUNIT_DRUPAL_SMTP_HOST=smtp.example.test -e FREEUNIT_DRUPAL_SMTP_FROM=a@example.test \
        -e FREEUNIT_DRUPAL_UPGRADE=1 -e FD_STUB_BOOTSTRAP=Successful "$@"; then
        t_uids=$(docker top "$prefix-anyuid-$t_role" -eo pid,uid | awk 'NR > 1 { print $2 }' | sort -u | tr '\n' ' ')
        check "anyuid-$t_role: every process runs as $any_uid" "$t_uids" [ "$t_uids" = "$any_uid " ]
        t_r=$(in_c "anyuid-$t_role" 'stat -c "%a %u" /run/msmtprc')
        check "anyuid-$t_role: /run/msmtprc is 0600 and owned by $any_uid" "$t_r" [ "$t_r" = "600 $any_uid" ]
    fi
done

# --- Compatibility with a 0.4.0-style site script ---

if start_web compat "$app_uid" "$compat_image"; then
    t_config=$(in_c compat 'curl -fsS --unix-socket /var/run/control.freeunit.sock http://localhost/config/listeners')
    check "compat: Unit runs the site's listener *:8090" "$(one_line "$t_config")" has "$t_config" '"*:8090"'
    t_files=$(in_c compat 'ls /run/docker-entrypoint.d')
    check "compat: one JSON in the generated dir, the site's" "$(one_line "$t_files")" [ "$t_files" = unit-config.json ]
    t_r=$(in_c compat 'cmp /run/msmtprc /fixtures/compat/msmtprc && echo same')
    check "compat: /run/msmtprc is the site's file byte for byte" "$(one_line "$t_r")" [ "$t_r" = same ]
    t_r=$(http compat 127.0.0.1:8090/)
    check "compat: without a site ini sendmail_path of embed is the wrapper" "$(one_line "$t_r")" has "$t_r" "sendmail=$wrapper_path body"
    t_r=$(in_c compat 'php -r "echo ini_get(\"sendmail_path\");"')
    check "compat: without a site ini sendmail_path of cli is the wrapper" "$t_r" [ "$t_r" = "$wrapper_path" ]
    t_r=$(in_c compat 'freeunit-drupal-sendmail --pretend')
    check "compat: the wrapper reads the site's /run/msmtprc" "$(one_line "$t_r")" has "$t_r" compat-smtp.invalid
fi

t_ini=/etc/php/$php_ver
if start_web compat-ini "$app_uid" \
    -v "$fixtures/compat/95-site-sendmail.ini:$t_ini/cli/conf.d/95-site-sendmail.ini:ro" \
    -v "$fixtures/compat/95-site-sendmail.ini:$t_ini/embed/conf.d/95-site-sendmail.ini:ro" "$compat_image"; then
    t_site='/usr/bin/msmtp -C /run/msmtprc --pretend -t -i'
    t_r=$(http compat-ini 127.0.0.1:8090/)
    check "compat-ini: the site's 95- ini wins for embed" "$(one_line "$t_r")" has "$t_r" "sendmail=$t_site body"
    t_r=$(in_c compat-ini 'php -r "echo ini_get(\"sendmail_path\");"')
    check "compat-ini: the site's 95- ini wins for cli" "$t_r" [ "$t_r" = "$t_site" ]
fi

expect_refusal compat-smtp 20-freeunit-drupal-msmtp.sh \
    '/run/msmtprc was written by an earlier script; unset FREEUNIT_DRUPAL_SMTP_HOST or drop that script' \
    -e FREEUNIT_DRUPAL_SMTP_HOST=smtp.example.test -e FREEUNIT_DRUPAL_SMTP_FROM=a@example.test "$compat_image"
expect_refusal compat-unit 30-freeunit-drupal-unit-config.sh \
    '/run/docker-entrypoint.d/unit-config.json was written by an earlier script; drop it or unset FREEUNIT_DRUPAL_UNIT_CONFIG' \
    -e FREEUNIT_DRUPAL_UNIT_CONFIG=1 "$compat_image"
expect_refusal static-json 30-freeunit-drupal-unit-config.sh \
    '/docker-entrypoint.d/config.json was written by an earlier script' \
    -e FREEUNIT_DRUPAL_UNIT_CONFIG=1 -v "$here/fixtures/config.json:/docker-entrypoint.d/config.json:ro" "$site_image"

t_dropin=$work/dropin
mkdir "$t_dropin" && chmod 0755 "$t_dropin" \
    && sed 's!%%APPLICATION_DIR%%!/www!g' "$fixtures/compat/unit-config.template" >"$t_dropin/config.json"
if start_web dropin "$app_uid" -e FREEUNIT_DRUPAL_UNIT_CONFIG=1 -e FREEUNIT_DRUPAL_SMTP_HOST=smtp.example.test \
    -e FREEUNIT_DRUPAL_SMTP_FROM=a@example.test -v "$t_dropin:/docker-entrypoint.d:ro" \
    -v "$fixtures/etc-msmtprc:/etc/msmtprc:ro" "$site_image"; then
    t_r=$(logs dropin)
    check "dropin: a dir over /docker-entrypoint.d hides the image scripts" "$(one_line "$(printf '%s\n' "$t_r" | grep freeunit-drupal- | head -n 2)")" \
        lacks "$t_r" 'launching /docker-entrypoint.d/'
    t_r=$(in_c dropin 'ls /run/docker-entrypoint.d; test -e /run/msmtprc && echo msmtprc')
    check "dropin: no freeunit-drupal.json and no /run/msmtprc" "$(one_line "$t_r")" [ -z "$t_r" ]
    t_config=$(in_c dropin 'curl -fsS --unix-socket /var/run/control.freeunit.sock http://localhost/config/applications')
    check "dropin: Unit serves the config of the dir" "$(one_line "$t_config")" has "$t_config" '"compat"'
    t_r=$(in_c dropin 'php -r "echo ini_get(\"sendmail_path\");"; echo; freeunit-drupal-sendmail --pretend')
    if has "$t_r" "$wrapper_path" && has "$t_r" nonexistent.invalid; then
        ok "dropin: mail goes through the wrapper and /etc/msmtprc"
    else
        fail "dropin: mail goes through the wrapper and /etc/msmtprc" "$(one_line "$t_r")"
    fi
fi

# Without a network the resolver answers "temporary failure": msmtp exits 75.
t_r=$(docker run --rm --network none --user "$app_uid:$app_uid" --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges --tmpfs "/run:size=16m,uid=$app_uid,gid=$app_uid,mode=0700" \
    --tmpfs "/tmp:size=16m,uid=$app_uid,gid=$app_uid,mode=0700" -v "$fixtures/etc-msmtprc:/etc/msmtprc:ro" \
    "$site_image" /bin/sh -c 'printf "b\n" | /usr/bin/msmtp -t to@example.test; echo msmtp=$?
        printf "b\n" | freeunit-drupal-sendmail -i to@example.test; echo wrapper=$?' 2>&1)
if has "$t_r" msmtp=75 && has "$t_r" wrapper=69; then
    ok "one-off: msmtp exits 75 on an unreachable relay, the wrapper 69"
else
    fail "one-off: msmtp exits 75 on an unreachable relay, the wrapper 69" "$(one_line "$t_r")"
fi
t_r=$(docker run --rm --network none --user "$app_uid:$app_uid" --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges --tmpfs "/run:size=16m,uid=$app_uid,gid=$app_uid,mode=0700" \
    --tmpfs "/tmp:size=16m,uid=$app_uid,gid=$app_uid,mode=0700" -v "$fixtures/etc-msmtprc:/etc/msmtprc:ro" \
    "$site_image" php -r 'var_dump(mail("to@example.test", "s", "b"));' 2>&1)
if has "$t_r" 'cannot locate host nonexistent.invalid' && has "$t_r" 'bool(false)'; then
    ok "one-off php mail(): msmtp fails on the host of /etc/msmtprc and mail() returns false"
else
    fail "one-off php mail(): msmtp fails on the host of /etc/msmtprc and mail() returns false" "$(one_line "$t_r")"
fi

# --- The shipped hardening check against the fixture site image ---

if docker run --rm --network none --entrypoint cat "$image" \
    /usr/local/share/freeunit-drupal/test/hardening-check.sh >"$work/hardening-check.sh" 2>/dev/null; then
    printf 'FREEUNIT_DRUPAL_SMTP_HOST=smtp.example.test\nFREEUNIT_DRUPAL_SMTP_FROM=a@example.test\n' >"$work/site.env"
    if FREEUNIT_DRUPAL_HARDENING_ENV_FILE=$work/site.env FREEUNIT_DRUPAL_HARDENING_WRITABLE_DIRS='/www/web/sites/default/files' \
        sh "$work/hardening-check.sh" --compose-copy "$here/../rootfs/usr/local/share/freeunit-drupal/docker-compose.hardening.yml" \
        "$site_image" >"$work/hardening.tap" 2>&1; then
        ok "hardening-check.sh of the image passes for the fixture site"
    else
        fail "hardening-check.sh of the image passes for the fixture site" "$(one_line "$(grep -e '^not ok' -e '^Bail' "$work/hardening.tap")")"
    fi
    sed 's/^/# /' "$work/hardening.tap"
else
    fail "hardening-check.sh is in the image"
fi

echo "1..$n"
[ "$failures" -eq 0 ]
