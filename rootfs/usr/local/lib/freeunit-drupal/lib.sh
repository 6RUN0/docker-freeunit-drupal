#!/bin/sh
#
# Library of the freeunit-drupal entrypoint scripts, sourced (`.`) by the
# /docker-entrypoint.d/NN-freeunit-drupal-*.sh scripts of the image and by a
# site's own scripts:
#
#   . /usr/local/lib/freeunit-drupal/lib.sh
#
# Public (stable since 0.5.0): freeunit_drupal_log_info, freeunit_drupal_log_notice,
# freeunit_drupal_log_warn, freeunit_drupal_die, freeunit_drupal_flag_enabled,
# freeunit_drupal_drush, freeunit_drupal_wait_for_db. Everything else here
# (the _fd_* names) and the base library functions this file sources are
# implementation details and may change in any release.
#
# Portable POSIX sh (dash in the image, busybox ash): no `local`, so every
# variable a function sets carries the _fd_<function>_ prefix.

# The base library gives the nginx-style log lines on fd 3 and die(). A script
# that sourced it already must not source it twice: its readonly assignments
# would fail.
if [ "$(command -v list_entrypoint_files 2>/dev/null)" != list_entrypoint_files ]; then
    . /docker-entrypoint-common.sh
fi

# --- Logging ---

freeunit_drupal_log_info() {
    log_info "freeunit-drupal: $*"
}

freeunit_drupal_log_notice() {
    log_notice "freeunit-drupal: $*"
}

freeunit_drupal_log_warn() {
    log_warn "freeunit-drupal: $*"
}

# Log at error level and exit 1. Called inside $(...) it ends only that
# subshell.
freeunit_drupal_die() {
    die "freeunit-drupal: $*"
}

# --- Variables ---

# Die unless NAME is a shell variable name. Args: <name>
_fd_assert_name() {
    case "$1" in
        '' | [0-9]* | *[!A-Za-z0-9_]*) freeunit_drupal_die "invalid variable name: '$1'" ;;
    esac
}

# Print the value of the variable NAME (empty when unset). Args: <name>
_fd_value_of() {
    _fd_assert_name "$1"
    eval "printf '%s' \"\${$1:-}\""
}

# True when the flag NAME is 1, false when it is unset, empty or 0; any other
# value dies, so a `yes` or `true` cannot be read as either. Args: <name>
freeunit_drupal_flag_enabled() {
    _fd_fe_value=$(_fd_value_of "$1") || exit 1
    case "$_fd_fe_value" in
        '' | 0) return 1 ;;
        1) return 0 ;;
    esac
    freeunit_drupal_die "$1 must be empty, 0 or 1, got '$_fd_fe_value'"
}

# Die naming the first of the variables that is unset or empty. Args: <name>...
_fd_require_env() {
    for _fd_re_name in "$@"; do
        _fd_re_value=$(_fd_value_of "$_fd_re_name") || exit 1
        [ -n "$_fd_re_value" ] || freeunit_drupal_die "$_fd_re_name is required"
    done
}

# Set the project layout defaults and export them, keeping a value the
# environment already has.
_fd_export_layout() {
    : "${FREEUNIT_DRUPAL_PROJECT_DIR:=/www}"
    : "${FREEUNIT_DRUPAL_DOCROOT:=$FREEUNIT_DRUPAL_PROJECT_DIR/web}"
    export FREEUNIT_DRUPAL_PROJECT_DIR FREEUNIT_DRUPAL_DOCROOT
}

# --- Drush ---

# Run the project's drush on the docroot, never prompting. The site URI comes
# from DRUSH_OPTIONS_URI in the environment. Args: <drush args>...
freeunit_drupal_drush() {
    _fd_assert_drush
    "$FREEUNIT_DRUPAL_PROJECT_DIR/vendor/bin/drush" --root="$FREEUNIT_DRUPAL_DOCROOT" --no-interaction "$@"
}

# Die unless the project ships an executable drush.
_fd_assert_drush() {
    _fd_export_layout
    [ -x "$FREEUNIT_DRUPAL_PROJECT_DIR/vendor/bin/drush" ] \
        || freeunit_drupal_die "drush not found at $FREEUNIT_DRUPAL_PROJECT_DIR/vendor/bin/drush (set FREEUNIT_DRUPAL_PROJECT_DIR, require drush/drush)"
}

# Wait until drush reaches the database (`sql:query 'SELECT 1'`), trying every
# 2 s for up to <seconds> (default FREEUNIT_DRUPAL_UPGRADE_DB_WAIT, else 60).
# Each attempt runs under timeout(1) with the time left: a database host that
# drops packets would hold the mysql client for minutes. On timeout die with
# the last line drush wrote to stderr: the cause (a refused connection, a
# settings.php exception) is in it. Args: [seconds]
freeunit_drupal_wait_for_db() {
    _fd_wfd_limit=${1:-${FREEUNIT_DRUPAL_UPGRADE_DB_WAIT:-60}}
    case "$_fd_wfd_limit" in
        '' | *[!0-9]*) freeunit_drupal_die "database wait must be a number of seconds, got '$_fd_wfd_limit'" ;;
    esac
    _fd_assert_drush
    _fd_wfd_start=$(date +%s)
    freeunit_drupal_log_info "waiting up to $_fd_wfd_limit s for the database"
    while :; do
        _fd_wfd_left=$((_fd_wfd_limit - ($(date +%s) - _fd_wfd_start)))
        [ "$_fd_wfd_left" -ge 1 ] || _fd_wfd_left=1
        if _fd_wfd_err=$(timeout -k 2 "$_fd_wfd_left" "$FREEUNIT_DRUPAL_PROJECT_DIR/vendor/bin/drush" \
            --root="$FREEUNIT_DRUPAL_DOCROOT" --no-interaction sql:query 'SELECT 1' 2>&1 >/dev/null); then
            return 0
        else
            _fd_wfd_rc=$?
        fi
        _fd_wfd_last=$(printf '%s\n' "$_fd_wfd_err" | sed '/^[[:space:]]*$/d' | tail -n 1)
        if [ "$_fd_wfd_rc" -eq 124 ] || [ "$_fd_wfd_rc" -eq 137 ]; then
            _fd_wfd_last="drush sql:query got no answer within $_fd_wfd_left s${_fd_wfd_last:+ ($_fd_wfd_last)}"
        fi
        _fd_wfd_left=$((_fd_wfd_limit - ($(date +%s) - _fd_wfd_start)))
        if [ "$_fd_wfd_left" -le 0 ]; then
            freeunit_drupal_die "database not reachable after $_fd_wfd_limit s: ${_fd_wfd_last:-drush printed no error}"
        fi
        if [ "$_fd_wfd_left" -gt 2 ]; then
            _fd_wfd_left=2
        fi
        sleep "$_fd_wfd_left"
    done
}

# --- Templates ---

# Render <template> into <out>: every %%NAME%% token, NAME an environment
# variable, is replaced by its value in a single pass, so a value is never
# expanded again. An undefined NAME, a newline in a value and, for
# <kind> json, a '"', a '\' or a control character in a value stop the render
# before <out> is written; a json result must parse. <out> is written under
# umask 077 next to its final name and renamed into place.
# Args: <template> <out> <kind: text|json>
_fd_render_template() {
    _fd_rt_template=$1
    _fd_rt_out=$2
    _fd_rt_kind=$3
    [ -r "$_fd_rt_template" ] || freeunit_drupal_die "template not readable: $_fd_rt_template"
    _fd_rt_tmp=$_fd_rt_out.tmp.$$
    if ! _fd_rt_err=$( (umask 077 && awk -v kind="$_fd_rt_kind" '
        function bad(msg) {
            if (!(msg in seen)) { seen[msg] = 1; errors = errors (errors == "" ? "" : "; ") msg }
        }
        {
            line = $0
            out = ""
            while ((i = index(line, "%%")) > 0) {
                rest = substr(line, i + 2)
                j = index(rest, "%%")
                if (j == 0) break
                name = substr(rest, 1, j - 1)
                if (name !~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
                    out = out substr(line, 1, i + 1)
                    line = rest
                    continue
                }
                out = out substr(line, 1, i - 1)
                line = substr(rest, j + 2)
                if (!(name in ENVIRON)) { bad("undefined variable " name); continue }
                value = ENVIRON[name]
                if (index(value, "\n") > 0) { bad("newline in the value of " name); continue }
                if (kind == "json" && (index(value, "\"") > 0 || index(value, "\\") > 0 || value ~ /[\001-\037\177]/)) {
                    bad("the value of " name " has a quote, a backslash or a control character")
                    continue
                }
                out = out value
            }
            print out line
        }
        END {
            if (errors != "") { print errors > "/dev/stderr"; exit 3 }
        }
    ' "$_fd_rt_template" >"$_fd_rt_tmp") 2>&1); then
        rm -f "$_fd_rt_tmp"
        freeunit_drupal_die "cannot render $_fd_rt_template into $_fd_rt_out: ${_fd_rt_err:-awk failed}"
    fi
    # shellcheck disable=SC2016 # PHP code, expanded by PHP
    if [ "$_fd_rt_kind" = json ] && ! _fd_rt_err=$(php -r '
        try {
            json_decode(file_get_contents($argv[1]), null, 512, JSON_THROW_ON_ERROR);
        } catch (JsonException $e) {
            fwrite(STDERR, $e->getMessage());
            exit(1);
        }' "$_fd_rt_tmp" 2>&1); then
        rm -f "$_fd_rt_tmp"
        freeunit_drupal_die "$_fd_rt_template rendered into $_fd_rt_out is not valid JSON: $_fd_rt_err"
    fi
    mv -f "$_fd_rt_tmp" "$_fd_rt_out" || freeunit_drupal_die "cannot write $_fd_rt_out as uid $(id -u)"
}
