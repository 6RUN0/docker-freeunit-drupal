#!/bin/sh
#
# First freeunit-drupal entrypoint script. Warns about every FREEUNIT_DRUPAL_*
# variable of the environment that the image does not know (a typo would
# otherwise switch nothing on, silently), then, when FREEUNIT_DRUPAL_WRITABLE_DIRS
# is set, stops the start unless each listed directory is writable and
# searchable for the process uid. Paths are separated by whitespace; a relative
# one is taken from FREEUNIT_DRUPAL_PROJECT_DIR. The container changes no
# ownership: a host dir must belong to the process uid.

set -eu

. /usr/local/lib/freeunit-drupal/lib.sh

fd_known=' PROJECT_DIR DOCROOT WRITABLE_DIRS UNIT_CONFIG UNIT_TEMPLATE UNIT_LISTEN
UNIT_MAX_BODY_SIZE UNIT_PROCESSES_MAX UNIT_PROCESSES_SPARE UNIT_PROCESS_IDLE_TIMEOUT
UNIT_LIMITS_TIMEOUT UNIT_LIMITS_REQUESTS PHP_MEMORY_LIMIT PHP_MAX_EXECUTION_TIME
PHP_POST_MAX_SIZE PHP_UPLOAD_MAX_FILESIZE PHP_TIMEZONE SMTP_HOST
SMTP_PORT SMTP_FROM SMTP_TLS SMTP_AUTH SMTP_USER SMTP_PASSWORD_FILE MSMTP_TEMPLATE
UPGRADE UPGRADE_DB_WAIT HEALTHCHECK_HOST HEALTHCHECK_PORT HEALTHCHECK_PATH
HEALTHCHECK_PROTO HEALTHCHECK_TIMEOUT RUN_UID RUN_GID TMP_DIR HARDENING_CRONTAB
HARDENING_WRITABLE_DIRS HARDENING_HOST HARDENING_ENV_FILE '
fd_known=$(printf '%s' "$fd_known" | tr '\n' ' ')

# shellcheck disable=SC2013 # variable names carry no whitespace
for fd_name in $(awk 'BEGIN { for (k in ENVIRON) if (k ~ /^FREEUNIT_DRUPAL_/) print k }'); do
    case "$fd_known" in
        *" ${fd_name#FREEUNIT_DRUPAL_} "*) ;;
        *) freeunit_drupal_log_warn "unknown variable $fd_name (typo?)" ;;
    esac
done

[ -n "${FREEUNIT_DRUPAL_WRITABLE_DIRS:-}" ] || exit 0

: "${FREEUNIT_DRUPAL_PROJECT_DIR:=/www}"
set -f
for fd_dir in $FREEUNIT_DRUPAL_WRITABLE_DIRS; do
    case "$fd_dir" in
        /*) ;;
        *) fd_dir=$FREEUNIT_DRUPAL_PROJECT_DIR/$fd_dir ;;
    esac
    if [ ! -d "$fd_dir" ] || [ ! -w "$fd_dir" ] || [ ! -x "$fd_dir" ]; then
        freeunit_drupal_die "$fd_dir is not a directory writable for uid $(id -u):$(id -g); the host dir or volume must belong to the process uid"
    fi
done
