#!/bin/sh
#
# When FREEUNIT_DRUPAL_UNIT_CONFIG=1, renders the Unit configuration from
# FREEUNIT_DRUPAL_UNIT_TEMPLATE (default: the built-in Drupal template) into
# $ENTRYPOINT_GENERATED_DIR/freeunit-drupal.json, which the base entrypoint
# applies after this round of scripts. PUT /config replaces the whole
# configuration, so another *.json in /docker-entrypoint.d or in the generated
# dir stops the start instead of silently winning or losing; the file this
# script wrote on a previous start does not count.

set -eu

. /usr/local/lib/freeunit-drupal/lib.sh

freeunit_drupal_flag_enabled FREEUNIT_DRUPAL_UNIT_CONFIG || exit 0

fd_out=$ENTRYPOINT_GENERATED_DIR/freeunit-drupal.json

_fd_export_layout
: "${FREEUNIT_DRUPAL_UNIT_TEMPLATE:=/usr/local/share/freeunit-drupal/unit.json.template}"
: "${FREEUNIT_DRUPAL_UNIT_LISTEN:=*:8080}"
: "${FREEUNIT_DRUPAL_UNIT_MAX_BODY_SIZE:=33554432}"
: "${FREEUNIT_DRUPAL_UNIT_PROCESSES_MAX:=8}"
: "${FREEUNIT_DRUPAL_UNIT_PROCESSES_SPARE:=2}"
: "${FREEUNIT_DRUPAL_UNIT_PROCESS_IDLE_TIMEOUT:=30}"
: "${FREEUNIT_DRUPAL_UNIT_LIMITS_TIMEOUT:=60}"
: "${FREEUNIT_DRUPAL_UNIT_LIMITS_REQUESTS:=1000}"
: "${FREEUNIT_DRUPAL_PHP_MEMORY_LIMIT:=256M}"
: "${FREEUNIT_DRUPAL_PHP_MAX_EXECUTION_TIME:=60}"
: "${FREEUNIT_DRUPAL_PHP_POST_MAX_SIZE:=32M}"
: "${FREEUNIT_DRUPAL_PHP_UPLOAD_MAX_FILESIZE:=32M}"
: "${FREEUNIT_DRUPAL_PHP_TIMEZONE:=UTC}"
export FREEUNIT_DRUPAL_UNIT_TEMPLATE FREEUNIT_DRUPAL_UNIT_LISTEN \
    FREEUNIT_DRUPAL_UNIT_MAX_BODY_SIZE FREEUNIT_DRUPAL_UNIT_PROCESSES_MAX \
    FREEUNIT_DRUPAL_UNIT_PROCESSES_SPARE FREEUNIT_DRUPAL_UNIT_PROCESS_IDLE_TIMEOUT \
    FREEUNIT_DRUPAL_UNIT_LIMITS_TIMEOUT FREEUNIT_DRUPAL_UNIT_LIMITS_REQUESTS \
    FREEUNIT_DRUPAL_PHP_MEMORY_LIMIT FREEUNIT_DRUPAL_PHP_MAX_EXECUTION_TIME \
    FREEUNIT_DRUPAL_PHP_POST_MAX_SIZE FREEUNIT_DRUPAL_PHP_UPLOAD_MAX_FILESIZE \
    FREEUNIT_DRUPAL_PHP_TIMEZONE

set -f
for fd_dir in "$ENTRYPOINT_CONFIG_DIR" "$ENTRYPOINT_GENERATED_DIR"; do
    fd_list=$(list_entrypoint_files "$fd_dir" .json) || exit 1
    for fd_file in $fd_list; do
        [ "$fd_file" = "$fd_out" ] && continue
        freeunit_drupal_die "$fd_file was written by an earlier script; drop it or unset FREEUNIT_DRUPAL_UNIT_CONFIG"
    done
done

_fd_render_template "$FREEUNIT_DRUPAL_UNIT_TEMPLATE" "$fd_out" json
