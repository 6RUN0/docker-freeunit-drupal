#!/bin/sh
#
# Entrypoint hook: add a "supercronic" launch mode to the freeunit-drupal image.
#
# COPYed into /docker-entrypoint-hook.d/ and SOURCED (`.`) by the base
# entrypoint, which already runs as the non-root container user (a root start
# is dropped to 65532 or refused before any hook is sourced). Portable POSIX sh:
# the entrypoint shell is not bash. Per the hook contract this file must ONLY
# define handle_<cmd> functions (no top-level side effects), and the handler
# MUST exec the final process - returning or exiting non-zero is a fatal
# contract violation the base dispatcher reports loudly. POSIX sh has no
# `local`: every variable the handler sets carries the supercronic_ prefix, so
# it cannot clobber the entrypoint's UNIT_*, ENTRYPOINT_* or _ep_* names. The dispatcher calls the handler left of `||`, so `set -e` does not
# apply inside it: every failure that matters is checked explicitly.
#
# Running the image with `supercronic` as its command makes the base entrypoint's
# dispatch_handler call handle_supercronic, which owns the launch instead of the
# default freeunitd (FreeUnit web server) path. The SAME image thus serves two
# roles - web server and cron runner - without overwriting /docker-entrypoint.sh,
# so every base-entrypoint robustness and security fix still applies here.

handle_supercronic() {
    # dispatch_handler invokes us as `handle_supercronic supercronic [args...]`,
    # so drop the command token; whatever the operator appended after the image's
    # `supercronic` command (their own flags, or a crontab path) remains in "$@".
    shift

    # Crontab baked in by the Dockerfile (rootfs/etc/supercronic/crontab);
    # override it either by mounting your own at the same path, or by passing a
    # different path as the trailing argument (see below).
    supercronic_crontab=/etc/supercronic/crontab

    # Run any operator *.sh drop-ins first - the same convenience the web role
    # gets from the first-run routine (a no-op when none are present).
    # run_entrypoint_scripts is a public base-library function and needs no
    # running daemon, so it is safe on this FreeUnit-less launch path.
    run_entrypoint_scripts

    # supercronic takes its crontab as the trailing positional argument and any
    # flags (-debug, -overlapping, -inotify, -prometheus-listen-address, ...)
    # before it. Pass the operator's arguments straight through so the launch is
    # fully tunable:
    # - trailing argument is an existing file: the operator owns the crontab;
    # - no argument, or the trailing one is a flag (starts with -): append the
    #   image default, so `... supercronic -debug` still runs the baked-in one;
    # - anything else (a mistyped path, or the value of a flag such as
    #   `-prometheus-listen-address :9746` with no crontab after it) dies here
    #   instead of supercronic printing its usage.
    #
    # The loop leaves supercronic_last set to the final positional argument
    # (empty when none were given); POSIX sh has no ${@: -1}. The same pass
    # notes whether the operator passed -no-reap.
    supercronic_last=
    supercronic_has_no_reap=
    for supercronic_last in "$@"; do
        case "$supercronic_last" in
            -no-reap | -no-reap=* | --no-reap | --no-reap=*) supercronic_has_no_reap=1 ;;
        esac
    done
    if [ -n "$supercronic_last" ] && [ -f "$supercronic_last" ]; then
        :
    elif [ -n "$supercronic_last" ] && [ "${supercronic_last#-}" = "$supercronic_last" ]; then
        die "supercronic crontab not found: $supercronic_last (pass an existing crontab file as the last argument, after any flag value)"
    else
        if [ ! -r "$supercronic_crontab" ]; then
            die "supercronic crontab not found or not readable: $supercronic_crontab"
        fi
        set -- "$@" "$supercronic_crontab"
    fi

    # tini is PID 1 and reaps orphaned job processes; supercronic's own reaper
    # would only log "process reaping disabled, not pid 1" on every start.
    # An explicit -no-reap or -no-reap=false from the operator wins.
    if [ -z "$supercronic_has_no_reap" ]; then
        set -- -no-reap "$@"
    fi

    log_notice "starting supercronic cron runner ($*)"

    # exec makes supercronic the container's main process (under tini), so it
    # receives signals directly. No privilege drop and no capability needed: the
    # entrypoint already runs as the container user, and so do the jobs.
    exec supercronic "$@"
}
