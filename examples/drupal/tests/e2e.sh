#!/bin/sh
#
# End-to-end test of the example: builds the site image FROM the given
# freeunit-drupal image, runs the whole stack (unit, cron, Varnish, MariaDB,
# Redis; OpenSearch with --search) under the hardening fragment, installs
# Drupal and checks the image scripts, the purge by cache tags, the trust of
# forwarding headers, cron, the services' hardening, a backend outage, the
# refusals of a foreign uid and of an empty salt, and the hardening check.
#
#   tests/e2e.sh [--search] <freeunit-drupal image>
#
#   --search  also start the compose profile search (OpenSearch), apply the
#             search recipe and index and find a node
#
# Environment:
#   E2E_AUDIT        block (default): a composer audit finding fails the
#                    test; report: it is printed as a TODO test
#   E2E_BUILD_EXTRA  extra flags for the image build (cache, CI)
#
# Every docker compose call uses its own project freeunit-drupal-e2e-<pid>,
# nothing is published on the host; the project, its volumes, the site image
# and the generated secrets are removed on exit. Output is TAP; the exit code
# is 1 when a test fails, 2 when a precondition does (Bail out!).

set -u

usage() {
    sed -n '10,19p' "$0" | sed 's/^# \{0,1\}//'
}

search=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --search) search=1; shift ;;
        --) shift; break ;;
        -*) echo "Bail out! unknown option $1"; exit 2 ;;
        *) break ;;
    esac
done
if [ "$#" -ne 1 ]; then
    echo "Bail out! usage: tests/e2e.sh [--search] <freeunit-drupal image>"
    exit 2
fi
image=$1
audit=${E2E_AUDIT:-block}
build_extra=${E2E_BUILD_EXTRA:-}
example=$(cd "$(dirname "$0")/.." && pwd)
project=freeunit-drupal-e2e-$$
site_image=$project-site:local
login_name=e2e-$$
host=localhost
foreign_uid=12345

n=0
failures=0
ok() { n=$((n + 1)); echo "ok $n - $1"; }
fail() { n=$((n + 1)); failures=$((failures + 1)); echo "not ok $n - $1${2:+ # got: $2}"; }
todo() { n=$((n + 1)); echo "not ok $n - $1 # TODO $2"; }
bail() { echo "Bail out! $1"; exit 2; }
# Records test $1 from the exit code of the command "$3...", reporting $2 on failure.
check() {
    t_name=$1
    t_got=$2
    shift 2
    if "$@"; then ok "$t_name"; else fail "$t_name" "$t_got"; fi
}
has() {
    case "$1" in
        *"$2"*) return 0 ;;
    esac
    return 1
}
lacks() { ! has "$1" "$2"; }
# True when $1 matches the extended regular expression $2.
matches() { printf '%s\n' "$1" | grep -q -E "$2"; }
one_line() { printf '%s' "$1" | tr '\n' ' ' | cut -c 1-300; }
# Runs "$3..." every $2 s until it succeeds or $1 s have passed.
poll() {
    t_limit=$1
    t_step=$2
    shift 2
    t_waited=0
    while :; do
        "$@" && return 0
        [ "$t_waited" -lt "$t_limit" ] || return 1
        sleep "$t_step"
        t_waited=$((t_waited + t_step))
    done
}

# --- Project plumbing ---

work=
stack_up=
redis_enable=0
run_uid=65532
tmp_dir=
salt_file=
# A start the test expects to be refused would run forever if it is not.
compose_timeout=
compose() {
    SITE_IMAGE=$site_image SITE_REDIS_ENABLE=$redis_enable \
        SITE_DB_PASSWORD_FILE=$work/secrets/db_password \
        SITE_DB_ROOT_PASSWORD_FILE=$work/secrets/db_root_password \
        SITE_REDIS_PASSWORD_FILE=$work/secrets/redis_password \
        SITE_HASH_SALT_FILE=$salt_file \
        FREEUNIT_DRUPAL_RUN_UID=$run_uid FREEUNIT_DRUPAL_RUN_GID=$run_uid \
        FREEUNIT_DRUPAL_TMP_DIR=$tmp_dir \
        ${compose_timeout:+timeout "$compose_timeout"} docker compose --project-directory "$example" --env-file "$work/e2e.env" \
        -f "$example/docker-compose.yml" -f "$example/tests/e2e.override.yml" \
        -p "$project" ${search:+--profile search} "$@"
}
in_unit() { compose exec -T unit "$@" 2>&1; }
in_cron() { compose exec -T cron "$@" 2>&1; }
site_drush() { compose exec -T cron drush "$@" 2>&1; }
container_of() { compose ps -a -q "$1" 2>/dev/null; }
# A directory the containers wrote into: emptied as root through the image.
wipe_dir() {
    [ -n "$1" ] && [ -d "$1" ] || return 0
    docker run --rm --user 0:0 --network none -v "$1:/d" --entrypoint /bin/sh "$image" \
        -c 'find /d -mindepth 1 -delete' >/dev/null 2>&1
    rmdir "$1" 2>/dev/null
}
squatter=
cleanup() {
    [ -z "$squatter" ] || docker rm -f "$squatter" >/dev/null 2>&1
    if [ -n "$stack_up" ]; then
        if [ "$failures" -gt 0 ]; then
            echo "# --- diagnostics ---"
            compose ps -a 2>&1 | sed 's/^/# /'
            compose logs --no-color --tail 40 2>&1 | sed 's/^/# /'
            site_drush watchdog:show --count=20 | sed 's/^/# /'
            for t_svc in unit cron varnish mariadb redis ${search:+opensearch}; do
                t_id=$(container_of "$t_svc")
                [ -n "$t_id" ] || continue
                echo "# $t_svc: $(docker inspect --format \
                    'ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}} CapDrop={{.HostConfig.CapDrop}} SecurityOpt={{.HostConfig.SecurityOpt}} User={{.Config.User}}' \
                    "$t_id" 2>&1)"
            done
        fi
        compose down -v --timeout 5 >/dev/null 2>&1
    fi
    docker rmi -f "$site_image" >/dev/null 2>&1
    if [ -n "$work" ]; then
        wipe_dir "$work/tmp"
        wipe_dir "$work/tmp-foreign"
        rm -rf "$work"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Prints a random hex value. GitHub Actions masks it in every later log line
# before anything can print it; the script never turns on command tracing.
new_secret() {
    t_value=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
    [ "${GITHUB_ACTIONS:-}" != true ] || echo "::add-mask::$t_value" >&2
    printf '%s' "$t_value"
}

# --- Preconditions ---

command -v docker >/dev/null 2>&1 || bail "docker not found"
compose_version=$(docker compose version --short 2>/dev/null) || bail "docker compose not found"
compose_major=$(printf '%s' "${compose_version#v}" | cut -d . -f 1)
compose_minor=$(printf '%s' "${compose_version#v}" | cut -d . -f 2)
case "$compose_major$compose_minor" in
    '' | *[!0-9]*) bail "cannot read the docker compose version: $compose_version" ;;
esac
# tests/e2e.override.yml drops the published port with !reset.
if [ "$compose_major" -lt 2 ] || { [ "$compose_major" -eq 2 ] && [ "$compose_minor" -lt 24 ]; }; then
    bail "docker compose $compose_version is older than 2.24 (needed for !reset)"
fi
docker image inspect "$image" >/dev/null 2>&1 || bail "no image $image"
case "$audit" in
    block | report) ;;
    *) bail "E2E_AUDIT must be block or report, got '$audit'" ;;
esac

work=$(mktemp -d) || bail "mktemp failed"
chmod 0700 "$work"
tmp_dir=$work/tmp
salt_file=$work/secrets/hash_salt

# --- 1. Site image ---

# The example builds FROM the published tag; here the tag is replaced by the
# image under test. A builder with the docker driver sees the local image;
# any other builder (docker-container in CI) gets it as an OCI layout.
from=$(sed -n 's/^FROM[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' "$example/Dockerfile" | head -n 1)
[ -n "$from" ] || bail "no FROM in $example/Dockerfile"
driver=$(docker buildx inspect 2>/dev/null | sed -n 's/^Driver:[[:space:]]*//p' | head -n 1)
if [ "$driver" = docker ]; then
    build_context="$from=docker-image://$image"
else
    mkdir "$work/base-oci" || bail "mkdir failed"
    docker save "$image" | tar -x -C "$work/base-oci" || bail "docker save $image failed"
    base_digest=$(sed -n 's/.*"digest":"\(sha256:[0-9a-f]\{64\}\)".*/\1/p' "$work/base-oci/index.json" | head -n 1)
    [ -n "$base_digest" ] || bail "no manifest digest in the OCI layout of $image"
    build_context="$from=oci-layout://$work/base-oci@$base_digest"
fi
# shellcheck disable=SC2086 # E2E_BUILD_EXTRA splits into flags
docker buildx build --load $build_extra --build-context "$build_context" -t "$site_image" "$example" \
    >"$work/build.log" 2>&1 || bail "building the site image ($driver driver): $(one_line "$(tail -n 5 "$work/build.log")")"
base_layers=$(docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$image")
site_layers=$(docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$site_image")
case "$site_layers" in
    "$base_layers"*) ok "the site image is built on the layers of $image ($driver driver)" ;;
    *) bail "the site image is not built on $image: its FROM resolved elsewhere" ;;
esac

if audit_out=$(docker run --rm --tmpfs /tmp -e COMPOSER_HOME=/tmp/composer --entrypoint composer "$site_image" \
    audit --locked --no-interaction --working-dir=/www 2>&1); then
    ok "composer audit --locked finds no advisory"
elif [ "$audit" = report ]; then
    todo "composer audit --locked finds no advisory" "$(one_line "$audit_out")"
else
    fail "composer audit --locked finds no advisory" "$(one_line "$audit_out")"
fi

# --- 2. Secrets and start ---

(
    umask 077
    mkdir "$work/secrets" "$work/tmp" || exit 1
    for t_name in db_password db_root_password redis_password hash_salt; do
        new_secret >"$work/secrets/$t_name" || exit 1
    done
    : >"$work/secrets/hash_salt_empty"
) || bail "cannot write the secrets"
# Compose secrets are bind mounts: the file mode of the host is what the
# containers see, and three uids read them.
chmod 0444 "$work/secrets"/*
docker run --rm --user 0:0 --network none -v "$work/tmp:/d" --entrypoint chown "$image" 65532:65532 /d \
    || bail "cannot chown the tmp dir"
admin_pass=$(new_secret)
printf '%s\n' "SITE_IMAGE=$site_image" "FREEUNIT_DRUPAL_TMP_DIR=$tmp_dir" \
    "SITE_DB_PASSWORD_FILE=$work/secrets/db_password" \
    "SITE_DB_ROOT_PASSWORD_FILE=$work/secrets/db_root_password" \
    "SITE_REDIS_PASSWORD_FILE=$work/secrets/redis_password" \
    "SITE_HASH_SALT_FILE=$salt_file" >"$work/e2e.env"

compose config -q 2>"$work/config.err" || bail "compose config: $(one_line "$(cat "$work/config.err")")"
stack_up=1
if ! compose up -d --wait --wait-timeout 180 >"$work/up.log" 2>&1; then
    fail "the stack starts and unit turns healthy" "$(one_line "$(tail -n 3 "$work/up.log")")"
    bail "the stack did not start"
fi
ok "the stack starts and unit turns healthy"
unit=$(container_of unit)
cron=$(container_of cron)
varnish=$(container_of varnish)

for t_svc in unit cron; do
    for t_name in db_password redis_password hash_salt; do
        # shellcheck disable=SC2016 # expanded in the container
        t_mode=$(compose exec -T "$t_svc" sh -c 'test -r "/run/secrets/$1" && stat -c %a "/run/secrets/$1"' sh "$t_name" 2>&1)
        check "$t_svc reads /run/secrets/$t_name under the tmpfs /run, mode 444" "$t_mode" [ "$t_mode" = 444 ]
    done
done

t_out=$(compose run --rm --no-deps -T varnish varnishd -C -n /var/lib/varnish/varnishd -f /etc/varnish/default.vcl 2>&1)
t_rc=$?
check "the VCL compiles with varnishd -C" "rc $t_rc: $(printf '%s\n' "$t_out" | grep -m 1 -i error)" [ "$t_rc" -eq 0 ]

# --- 3. Before the installation ---

code() { printf '%s' "$1" | tail -n 1; }
t_out=$(in_unit curl -s -o /dev/null -w '%{http_code}' -H "Host: $host" http://127.0.0.1:8080/)
check "GET / through Unit before the installation is 302" "$t_out" [ "$t_out" = 302 ]
t_running=$(docker inspect --format '{{.State.Running}}' "$cron" 2>&1)
check "cron keeps running before the installation" "$t_running" [ "$t_running" = true ]
t_logs=$(docker logs "$cron" 2>&1)
check "cron ran 90-freeunit-drupal-upgrade.sh" "" has "$t_logs" 'launching /docker-entrypoint.d/90-freeunit-drupal-upgrade.sh'
check "90- skipped the upgrade of the site that is not installed" "" has "$t_logs" 'Drupal not installed, skipping upgrade'
t_out=$(in_unit curl -s -o /dev/null -w '%{http_code}' -H "Host: $host" http://127.0.0.1:8080/core/misc/drupal.js)
check "Unit serves the static /core/misc/drupal.js" "$t_out" [ "$t_out" = 200 ]
t_out=$(in_unit curl -fsS --unix-socket /var/run/control.freeunit.sock http://localhost/config/listeners)
check "Unit runs the rendered configuration (*:8080)" "$(one_line "$t_out")" has "$t_out" '"*:8080"'
t_out=$(site_drush sql:query 'SELECT 1')
check "drush reaches the database" "$(one_line "$t_out")" [ "$(code "$t_out")" = 1 ]

# --- 4. Installation ---

settings_sum() { in_unit sha256sum /www/web/sites/default/settings.php; }
sum_before=$(settings_sum)
if site_drush site:install minimal --yes --account-name=admin --account-pass="$admin_pass" \
    --site-name=freeunit-drupal-e2e >"$work/install.log" 2>&1; then
    ok "drush site:install minimal"
else
    fail "drush site:install minimal" "$(one_line "$(tail -n 5 "$work/install.log")")"
fi
sum_after=$(settings_sum)
check "site:install left the read-only settings.php as it was" "$sum_after" [ "$sum_after" = "$sum_before" ]
t_out=$(site_drush status --field=bootstrap)
check "drush status reports bootstrap Successful" "$(one_line "$t_out")" has "$t_out" Successful

# --- 5. Stack recipe and Redis ---

t_out=$(site_drush recipe /www/recipes/freeunit_drupal_stack)
t_rc=$?
check "the recipe freeunit_drupal_stack applies" "$(one_line "$t_out")" [ "$t_rc" -eq 0 ]
redis_enable=1
varnish_started=$(docker inspect --format '{{.State.StartedAt}}' "$varnish" 2>&1)
if compose up -d --wait --wait-timeout 180 >"$work/up.log" 2>&1; then
    ok "unit and cron restart with SITE_REDIS_ENABLE=1"
else
    fail "unit and cron restart with SITE_REDIS_ENABLE=1" "$(one_line "$(tail -n 3 "$work/up.log")")"
fi
unit=$(container_of unit)
cron=$(container_of cron)
varnish=$(container_of varnish)
t_out=$(docker inspect --format '{{.State.StartedAt}}' "$varnish" 2>&1)
check "Varnish keeps running (and its cache) while unit is recreated" "$t_out" [ "$t_out" = "$varnish_started" ]
t_logs=$(docker logs "$cron" 2>&1)
check "cron ran drush updb on the installed site" "" has "$t_logs" 'freeunit-drupal: drush updb --yes'
check "cron logs no failed upgrade step" "$(printf '%s' "$t_logs" | grep -m 1 'failed')" lacks "$t_logs" 'failed'
t_restarts=$(docker inspect --format '{{.RestartCount}}' "$cron" 2>&1)
check "cron did not restart" "$t_restarts" [ "$t_restarts" = 0 ]
# shellcheck disable=SC2016 # PHP code
t_out=$(site_drush php:eval 'echo get_class(\Drupal::cache("render"));')
check "the render cache is the Redis backend" "$(one_line "$t_out")" has "$t_out" 'Drupal\redis\Cache'
# shellcheck disable=SC2016 # expanded in the container
t_out=$(compose exec -T redis sh -c 'REDISCLI_AUTH="$(cat /run/secrets/redis_password)" redis-cli dbsize' 2>&1)
check "Redis holds keys (redis-cli with the password)" "$(one_line "$t_out")" matches "$(code "$t_out")" '^[1-9][0-9]*$'
t_out=$(compose exec -T redis redis-cli dbsize 2>&1)
check "Redis refuses a client without the password (NOAUTH)" "$(one_line "$t_out")" has "$t_out" NOAUTH

# --- 6. Pages, Varnish and purge ---

backend_is() { compose exec -T varnish varnishadm backend.list 2>&1 | grep -q -i " $1 "; }
check "Varnish marks unit healthy" "$(one_line "$(compose exec -T varnish varnishadm backend.list 2>&1)")" \
    poll 120 2 backend_is healthy

# Prints the status, then the headers of a GET of $2 on $1 (unit or varnish).
get() {
    case "$1" in
        unit) t_url=http://127.0.0.1:8080$2 ;;
        *) t_url=http://varnish$2 ;;
    esac
    shift 2
    in_unit curl -s -o /dev/null -D - -H "Host: $host" "$@" "$t_url" | tr -d '\r'
}
cache_status() { printf '%s' "$1" | sed -n 's/^X-Cache-Status: //Ip' | head -n 1; }
status_of() { printf '%s' "$1" | sed -n 's/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' | head -n 1; }
is_hit() {
    t_head=$(get varnish "$1")
    [ "$(cache_status "$t_head")" = HIT ]
}

t_head=$(get unit /)
check "Unit answers / with X-Generator: Drupal" "$(one_line "$t_head")" has "$t_head" 'X-Generator: Drupal'
t_head=$(get varnish /)
check "Varnish answers / with 200 and MISS" "$(status_of "$t_head") $(cache_status "$t_head")" \
    [ "$(status_of "$t_head") $(cache_status "$t_head")" = '200 MISS' ]
check "Varnish answers / again with HIT" "$(cache_status "$(get varnish /)")" poll 10 1 is_hit /
check "Varnish turns /core/misc/drupal.js into a HIT" "$(cache_status "$(get varnish /core/misc/drupal.js)")" \
    poll 10 1 is_hit /core/misc/drupal.js
# A browser on the published port sends the port in Host; Varnish strips it.
t_out=$(in_unit curl -s -o /dev/null -w '%{http_code}' -H "Host: $host:8080" http://varnish/)
check "GET / with Host $host:8080 (the README URL) is 200" "$t_out" [ "$t_out" = 200 ]

t_out=$(site_drush config:get purge.plugins purgers)
check "the Varnish purger is registered in purge.plugins" "$(one_line "$t_out")" has "$t_out" varnishbundled
site_name=freeunit-drupal-e2e-renamed-$$
# Prints counter $1 of the purge queue statistics, or nothing.
queue_stat() { site_drush p:queue-stats --format=json | sed -n "s/.*\"$1\": *\([0-9][0-9]*\).*/\1/p"; }
succeeded_before=$(queue_stat total_succeeded)
site_drush config:set system.site name "$site_name" --yes >/dev/null
items=$(queue_stat number_of_items)
succeeded_after=$(queue_stat total_succeeded)
case "$succeeded_before:$items:$succeeded_after" in
    *[!0-9:]* | :* | *::* | *:)
        fail "the tag invalidation is queued" "unreadable queue statistics: $succeeded_before:$items:$succeeded_after" ;;
    *)
        # The cron processor (every minute) may have taken the item already.
        queued=$((items + succeeded_after - succeeded_before))
        check "the tag invalidation is queued" "$queued item(s)" [ "$queued" -ge 1 ] ;;
esac
t_out=$(site_drush p:queue-work)
t_rc=$?
check "drush p:queue-work succeeds" "$(one_line "$t_out")" [ "$t_rc" -eq 0 ]
t_out=$(queue_stat number_of_items)
check "the purge queue is empty afterwards" "$t_out item(s)" [ "$t_out" = 0 ]
t_out=$(compose exec -T varnish varnishadm ban.list 2>&1)
check "varnishadm ban.list holds the ban of config:system.site (dots escaped)" "$(one_line "$t_out")" \
    has "$t_out" 'config:system\.site'
t_page=$(in_unit curl -s -D - -H "Host: $host" http://varnish/ | tr -d '\r')
check "the page is a MISS after the ban" "$(cache_status "$t_page")" [ "$(cache_status "$t_page")" = MISS ]
check "the page carries the new site name" "" has "$t_page" "$site_name"
check "/core/misc/drupal.js stays a HIT (the ban is selective)" "$(cache_status "$(get varnish /core/misc/drupal.js)")" \
    is_hit /core/misc/drupal.js

# Selectivity on a tagged object: tags / does not carry, one of them a prefix
# of a tag it carries, one equal to it but for a regex dot, leave it cached.
t_head=$(get unit /)
check "/ carries the cache tag config:block_list" "$(one_line "$t_head")" matches "$t_head" '^X-Drupal-Cache-Tags:.* config:block_list( |$)'
check "/ is a HIT before the invalidations" "$(cache_status "$(get varnish /)")" poll 10 1 is_hit /
for t_tag in node:999999999 config:block config:block.list; do
    t_out=$(site_drush p:invalidate tag "$t_tag")
    t_rc=$?
    check "drush p:invalidate tag $t_tag" "$(one_line "$t_out")" [ "$t_rc" -eq 0 ]
done
check "/ stays a HIT: none of those tags is one of its tags" "$(cache_status "$(get varnish /)")" is_hit /
t_out=$(site_drush p:invalidate tag config:block_list)
t_head=$(get varnish /)
check "/ is a MISS after its tag config:block_list is invalidated" "$(cache_status "$t_head")" \
    [ "$(cache_status "$t_head")" = MISS ]

ban() { in_unit curl -s -o /dev/null -w '%{http_code}' -X BAN -H "Cache-Host: $host" "$@"; }
t_out=$(ban -H 'Cache-Tags: node_list' http://varnish:80/)
check "BAN on the http listener is 405" "$t_out" [ "$t_out" = 405 ]
for t_tags in '.*' 'a||b' '|'; do
    t_out=$(ban -H "Cache-Tags: $t_tags" http://varnish:8081/)
    check "BAN on the purge listener with Cache-Tags '$t_tags' is 400" "$t_out" [ "$t_out" = 400 ]
done
t_out=$(in_unit curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://varnish:8443/; echo " rc=$?")
check "the PROXY listener :8443 does not exist" "$t_out" has "$t_out" 'rc=7'

# --- 7. Forwarding headers, files, bodies ---

# Drupal logs the name only for an existing account.
t_out=$(site_drush user:create "$login_name" --password="$(new_secret)")
check "drush user:create $login_name" "$(one_line "$t_out")" has "$t_out" "Created a new user"

t_page=$(in_unit curl -s -H "Host: $host" http://varnish/user/login)
form_build_id=$(printf '%s' "$t_page" | sed -n 's/.*name="form_build_id" value="\([^"]*\)".*/\1/p' | head -n 1)
check "GET /user/login through Varnish carries a form_build_id" "" [ -n "$form_build_id" ]
t_out=$(in_unit curl -s -o /dev/null -w '%{http_code}' -H "Host: $host" -H 'X-Real-IP: 203.0.113.9' \
    -H 'X-Forwarded-For: 203.0.113.9' -H 'X-Forwarded-Host: forged.example' -H 'X-Forwarded-Port: 1337' \
    -H 'X-Forwarded-Proto: https' -H 'Forwarded: for=203.0.113.9;proto=https' \
    --data-urlencode "name=$login_name" --data-urlencode 'pass=wrong' \
    --data-urlencode "form_build_id=$form_build_id" --data-urlencode 'form_id=user_login_form' \
    --data-urlencode 'op=Log in' http://varnish/user/login)
check "POST /user/login with a wrong password through Varnish is answered" "$t_out" [ "$t_out" = 200 ]
t_out=$(site_drush sql:query "SELECT hostname FROM watchdog WHERE type = 'user' AND message LIKE 'Login attempt failed for %' AND variables LIKE '%\"$login_name\"%' ORDER BY wid DESC LIMIT 1")
login_host=$(code "$t_out")
check "watchdog has 'Login attempt failed' for $login_name" "$(one_line "$t_out")" [ -n "$login_host" ]
unit_edge_ip=$(docker inspect --format "{{(index .NetworkSettings.Networks \"${project}_edge\").IPAddress}}" "$unit" 2>&1)
varnish_ip=$(docker inspect --format "{{(index .NetworkSettings.Networks \"${project}_edge\").IPAddress}}" "$varnish" 2>&1)
check "its hostname is the edge address of the client container ($unit_edge_ip)" "$login_host" \
    [ "$login_host" = "$unit_edge_ip" ]
check "its hostname is neither the client's X-Real-IP nor Varnish ($varnish_ip)" "$login_host" \
    lacks " 203.0.113.9 $varnish_ip " " $login_host "
# What Varnish sent to Unit for that POST: Drupal would ignore most forged
# headers anyway, so the VCL itself is checked here.
t_log=$(compose exec -T varnish varnishlog -d -g request -i BereqHeader \
    -q 'ReqMethod eq "POST" and ReqURL eq "/user/login"' 2>&1)
t_xff=$(printf '%s\n' "$t_log" | sed -n 's/.*BereqHeader[[:space:]]*X-Forwarded-For: //Ip' | tr '\n' ' ')
check "Varnish sends X-Forwarded-For: <client address> only" "$(one_line "$t_log")" [ "$t_xff" = "$unit_edge_ip " ]
t_forged=$(printf '%s\n' "$t_log" | grep -i -E 'BereqHeader[[:space:]]*(X-Real-IP|X-Forwarded-(Host|Port|Proto)|Forwarded):')
check "Varnish drops the client's X-Real-IP, X-Forwarded-Host/Port/Proto and Forwarded" "$(one_line "$t_forged")" \
    [ -z "$t_forged" ]
for t_extra in 'X-Forwarded-Port: 1337' ''; do
    t_head=$(get varnish /user ${t_extra:+-H "$t_extra"})
    t_location=$(printf '%s' "$t_head" | sed -n 's/^Location: //Ip' | head -n 1)
    check "GET /user${t_extra:+ with $t_extra} redirects to http://$host/user/login" "$t_location" \
        [ "$t_location" = "http://$host/user/login" ]
done

# shellcheck disable=SC2016 # PHP code
t_out=$(site_drush php:eval '$f = \Drupal::service("file.repository")->writeData("managed-'"$$"'", "public://e2e-'"$$"'.txt"); echo $f->createFileUrl();')
file_path=$(code "$t_out")
for t_via in unit varnish; do
    case "$t_via" in
        unit) t_url=http://127.0.0.1:8080$file_path ;;
        *) t_url=http://varnish$file_path ;;
    esac
    t_body=$(in_unit curl -s -H "Host: $host" "$t_url")
    check "a managed file is served through $t_via" "$(one_line "$t_body")" [ "$t_body" = "managed-$$" ]
done
# shellcheck disable=SC2016 # PHP code
site_drush php:eval '\Drupal::service("file.repository")->writeData("<?php echo \"executed\";", "public://probe.php");' >/dev/null
for t_via in unit varnish; do
    case "$t_via" in
        unit) t_url=http://127.0.0.1:8080/sites/default/files/probe.php ;;
        *) t_url=http://varnish/sites/default/files/probe.php ;;
    esac
    t_out=$(in_unit curl -s -w '\n%{http_code}' -H "Host: $host" "$t_url")
    check "PHP under sites/default/files is 404 through $t_via" "$(one_line "$t_out")" [ "$(code "$t_out")" = 404 ]
    check "PHP under sites/default/files is neither run nor served as source through $t_via" "$(one_line "$t_out")" \
        lacks "$t_out" executed
done
# shellcheck disable=SC2016 # expanded in the container
t_out=$(in_unit sh -c 'f=$(mktemp) && head -c 1048576 /dev/urandom >"$f" \
    && curl -s -o /dev/null -D - -H "Host: localhost" -F "file=@$f" http://127.0.0.1:8080/; rm -f "$f"')
check "a 1 MB POST reaches Drupal through Unit" "$(one_line "$t_out")" has "$t_out" 'X-Generator: Drupal'
# Through Varnish too (the reqwest client carries the body); Varnish strips
# X-Generator, so the status tells: 200 from Drupal, not 413 or 503.
# shellcheck disable=SC2016 # expanded in the container
t_out=$(in_unit sh -c 'f=$(mktemp) && head -c 8388608 /dev/urandom >"$f" \
    && curl -s -o /dev/null -w "%{http_code}" -H "Host: localhost" -F "file=@$f" http://varnish/; rm -f "$f"')
check "an 8 MB POST reaches Drupal through Varnish" "$t_out" [ "$t_out" = 200 ]
# shellcheck disable=SC2016 # PHP code
site_drush php:eval '\Drupal::service("file.repository")->writeData(random_bytes(20971520), "public://e2e-large-'"$$"'.bin");' >/dev/null
t_out=$(in_unit curl -s -o /dev/null -w '%{http_code} %{size_download}' -H "Host: $host" \
    "http://varnish/sites/default/files/e2e-large-$$.bin")
check "a 20 MB file is served whole through Varnish" "$t_out" [ "$t_out" = '200 20971520' ]

# --- 8. Cron ---

t0=$(code "$(site_drush php:eval 'echo time();')")
cron_ran() {
    t_last=$(code "$(site_drush state:get system.cron_last)")
    case "$t_last" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "$t_last" -gt "$t0" ]
}
check "supercronic runs drush cron (system.cron_last moves past $t0)" "" poll 150 5 cron_ran
t_logs=$(docker logs "$cron" 2>&1)
check "supercronic logs job succeeded for drush cron" "" matches "$t_logs" 'job succeeded.*drush cron'

# --- 9. Services ---

for t_svc in varnish mariadb redis; do
    t_id=$(container_of "$t_svc")
    t_out=$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}' "$t_id" 2>&1)
    check "$t_svc: read-only rootfs, every capability dropped, no-new-privileges" "$t_out" \
        [ "$t_out" = 'true [ALL] [no-new-privileges:true]' ]
done
for t_pair in mariadb:999 redis:999 varnish:1000; do
    t_svc=${t_pair%%:*}
    t_uid=${t_pair#*:}
    t_uids=$(docker top "$(container_of "$t_svc")" -eo pid,uid | awk 'NR > 1 { print $2 }' | sort -u | tr '\n' ' ')
    check "$t_svc: every process runs as uid $t_uid" "$t_uids" [ "$t_uids" = "$t_uid " ]
done
for t_svc in unit cron; do
    t_out=$(compose exec -T "$t_svc" sh -c 'test -e /run/secrets/db_root_password && echo present' 2>&1)
    check "$t_svc has no /run/secrets/db_root_password" "$t_out" [ -z "$t_out" ]
done
t_out=$(compose exec -T varnish sh -c 'test -e /run/secrets && echo present' 2>&1)
check "varnish has no /run/secrets" "$t_out" [ -z "$t_out" ]

# --- 10. Backend down ---

# A page cached for 5 s must still be served once its TTL is over and the
# backend is down: grace (24 h).
grace_url="/?e2e-grace=$$"
site_drush config:set system.performance cache.page.max_age 5 --yes >/dev/null
check "$grace_url is a HIT with a 5 s TTL" "$(cache_status "$(get varnish "$grace_url")")" poll 10 1 is_hit "$grace_url"
check "/ is a HIT in Varnish before unit stops" "$(cache_status "$(get varnish /)")" poll 10 1 is_hit /
unit_ip_before=$(docker inspect --format "{{(index .NetworkSettings.Networks \"${project}_edge\").IPAddress}}" "$unit" 2>&1)
compose stop --timeout 10 unit >/dev/null 2>&1
check "Varnish marks the stopped unit sick" "" poll 120 2 backend_is sick
# Prints status and Age of a GET of $1 through Varnish from cron.
get_from_cron() {
    in_cron curl -s -o /dev/null -D - -H "Host: $host" "http://varnish$1" | tr -d '\r' \
        | sed -n -e 's/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' -e 's/^Age: \([0-9]*\)/\1/Ip' | tr '\n' ' '
}
in_grace() {
    t_got=$(get_from_cron "$grace_url")
    t_age=${t_got#* }
    t_age=${t_age%% *}
    case "$t_got:$t_age" in
        '200 '*:[0-9]*) [ "$t_age" -gt 5 ] ;;
        *) return 1 ;;
    esac
}
check "Varnish serves $grace_url past its TTL from grace while unit is down" "$(get_from_cron "$grace_url")" \
    poll 30 2 in_grace
t_out=$(in_cron curl -s -o /dev/null -w '%{http_code}' -H "Host: $host" http://varnish/)
check "Varnish serves / from its cache while unit is down" "$t_out" [ "$t_out" = 200 ]
t_out=$(in_cron curl -s -o /dev/null -w '%{http_code}' -X BAN -H "Cache-Host: $host" -H 'Cache-Tags: node_list' http://varnish:8081/)
check "BAN while unit is down is 403" "$t_out" [ "$t_out" = 403 ]
# Another container takes the address unit had; unit comes back on another.
squatter=$project-squatter
if t_out=$(docker run -d --rm --name "$squatter" --network "${project}_edge" --entrypoint sleep "$image" 600 2>&1); then
    ok "a container takes the edge address of the stopped unit"
else
    fail "a container takes the edge address of the stopped unit" "$(one_line "$t_out")"
    squatter=
fi
compose start unit >/dev/null 2>&1
check "Varnish marks unit healthy again" "" poll 120 2 backend_is healthy
unit_ip_after=$(docker inspect --format "{{(index .NetworkSettings.Networks \"${project}_edge\").IPAddress}}" "$unit" 2>&1)
check "unit comes back on another address ($unit_ip_before -> $unit_ip_after)" "$unit_ip_after" \
    [ "$unit_ip_after" != "$unit_ip_before" ]
t_out=$(get varnish "/?e2e-moved=$$")
check "Varnish follows unit to $unit_ip_after without a restart" \
    "$(status_of "$t_out")" [ "$(status_of "$t_out")" = 200 ]
[ -z "$squatter" ] || docker rm -f "$squatter" >/dev/null 2>&1
squatter=
site_drush config:set system.performance cache.page.max_age 3600 --yes >/dev/null

# --- 11. Foreign uid ---

# One-off cron containers run the entrypoint scripts like the service does
# (the service command, supercronic): a refused start exits, an accepted one
# would run until the timeout.
expect_refusal() {
    t_name=$1
    shift
    compose_timeout=90
    t_out=$("$@" 2>&1)
    t_rc=$?
    compose_timeout=
    if [ "$t_rc" -eq 124 ]; then
        fail "$t_name" "container kept running"
        return 1
    fi
    check "$t_name: the start is refused" "rc $t_rc" [ "$t_rc" -ne 0 ]
}
mkdir "$work/tmp-foreign" || bail "mkdir failed"
docker run --rm --user 0:0 --network none -v "$work/tmp-foreign:/d" --entrypoint chown "$image" \
    "$foreign_uid:$foreign_uid" /d || bail "cannot chown the foreign tmp dir"
run_uid=$foreign_uid
tmp_dir=$work/tmp-foreign
if expect_refusal "cron as uid $foreign_uid" compose run --rm --no-deps -T cron; then
    check "it names 10-freeunit-drupal-writable-dirs.sh" "$(one_line "$t_out")" \
        has "$t_out" 'entrypoint script failed (exit 1): /docker-entrypoint.d/10-freeunit-drupal-writable-dirs.sh'
    check "it names web/sites/default/files and uid $foreign_uid" "$(one_line "$t_out")" \
        has "$t_out" "web/sites/default/files is not a directory writable for uid $foreign_uid"
fi
run_uid=65532
tmp_dir=$work/tmp

# --- 12. Empty salt ---

salt_file=$work/secrets/hash_salt_empty
if expect_refusal "cron with an empty salt file" compose run --rm --no-deps -T -e FREEUNIT_DRUPAL_UPGRADE_DB_WAIT=4 cron; then
    t_line=$(printf '%s\n' "$t_out" | grep -m 1 'database not reachable')
    check "the upgrade wait names SITE_HASH_SALT_FILE as the cause" "$(one_line "$t_line")" \
        has "$t_line" SITE_HASH_SALT_FILE
fi
salt_file=$work/secrets/hash_salt

# --- 13. Search (--search) ---

if [ -n "$search" ]; then
    os=$(container_of opensearch)
    t_out=$(docker inspect --format '{{.State.Health.Status}}' "$os" 2>&1)
    check "opensearch is healthy" "$t_out" [ "$t_out" = healthy ]
    t_uids=$(docker top "$os" -eo pid,uid | awk 'NR > 1 { print $2 }' | sort -u | tr '\n' ' ')
    check "opensearch: every process runs as uid 1000" "$t_uids" [ "$t_uids" = '1000 ' ]
    t_out=$(docker inspect --format '{{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}' "$os" 2>&1)
    check "opensearch: every capability dropped, no-new-privileges" "$t_out" [ "$t_out" = '[ALL] [no-new-privileges:true]' ]
    t_out=$(site_drush recipe /www/recipes/freeunit_drupal_search)
    t_rc=$?
    check "the recipe freeunit_drupal_search applies" "$(one_line "$t_out")" [ "$t_rc" -eq 0 ]
    # shellcheck disable=SC2016 # PHP code
    site_drush php:eval '\Drupal\node\Entity\Node::create(["type" => "page", "title" => "searchable '"$$"'"])->save();' >/dev/null
    t_out=$(site_drush search-api:index content)
    t_rc=$?
    check "drush search-api:index content" "$(one_line "$t_out")" [ "$t_rc" -eq 0 ]
    found() { site_drush search-api:search content "searchable" | grep -q "searchable $$"; }
    check "drush search-api:search finds the node" "" poll 30 2 found
fi

# --- 14. Hardening check ---

docker run --rm --network none --entrypoint cat "$image" /usr/local/share/freeunit-drupal/test/hardening-check.sh \
    >"$work/hardening-check.sh" 2>/dev/null || bail "$image has no hardening-check.sh"
t_out=$(FREEUNIT_DRUPAL_HARDENING_WRITABLE_DIRS='/www/web/sites/default/files /www/private' \
    sh "$work/hardening-check.sh" --compose-copy "$example/docker-compose.hardening.yml" "$site_image" 2>&1)
t_rc=$?
printf '%s\n' "$t_out" | sed 's/^/# /'
check "hardening-check.sh passes on the site image" "rc $t_rc: $(printf '%s\n' "$t_out" | grep -m 1 '^not ok')" [ "$t_rc" -eq 0 ]

echo "1..$n"
[ "$failures" -eq 0 ]
