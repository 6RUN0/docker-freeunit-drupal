#!/usr/bin/env bash
#
# Entrypoint hook: add a "supercronic" launch mode to the freeunit-drupal image.
#
# COPYed into /docker-entrypoint-hook.d/ and SOURCED by the base entrypoint as
# root, before any privilege drop. Per the hook contract this file must ONLY
# define handle_<cmd> functions (no top-level side effects), and the handler MUST
# exec the final process — returning or exiting non-zero is a fatal contract
# violation the base dispatcher reports loudly.
#
# Running the image with `supercronic` as its command makes the base entrypoint's
# dispatch_handler call handle_supercronic, which owns the launch instead of the
# default freeunitd (FreeUnit web server) path. The SAME image thus serves two roles —
# web server and cron runner — without overwriting /docker-entrypoint.sh, so
# every base-entrypoint robustness and security fix still applies here.

handle_supercronic() {
    # dispatch_handler invokes us as `handle_supercronic supercronic [args...]`,
    # so drop the command token; whatever the operator appended after the image's
    # `supercronic` command (their own flags, or a crontab path) remains in "$@".
    shift

    # Crontab baked in by the Dockerfile (rootfs/etc/supercronic/crontab);
    # override it either by mounting your own at the same path, or by passing a
    # different path as the trailing argument (see below). Declared local to keep
    # this file's global scope to handler definitions only, as the contract requires.
    local crontab=/etc/supercronic/crontab

    # Run any operator *.sh drop-ins first — the same convenience the web role
    # gets from the first-run routine (a no-op when none are present).
    # run_entrypoint_scripts is a public base-library function and needs no
    # running daemon, so it is safe on this FreeUnit-less launch path.
    run_entrypoint_scripts

    # supercronic takes its crontab as the trailing positional argument and any
    # flags (-debug, -overlapping, -inotify, -prometheus-listen-address, ...)
    # before it. Pass the operator's arguments straight through so the launch is
    # fully tunable. When their trailing argument already names a readable file
    # they own the crontab too; otherwise append the image default, so adding a
    # flag (`... supercronic -debug`) still runs the baked-in crontab.
    #
    # The loop leaves $lastArg set to the final positional argument (empty when
    # none were given) without the array-in-[ ] pitfall of ${@: -1}.
    local lastArg=
    for lastArg in "$@"; do :; done
    if [ -z "$lastArg" ] || [ ! -f "$lastArg" ]; then
        if [ ! -r "$crontab" ]; then
            die "supercronic crontab not found or not readable: $crontab"
        fi
        set -- "$@" "$crontab"
    fi

    log_notice "starting supercronic cron runner ($*)"

    # Drop root -> the app user and exec the runner, so supercronic becomes the
    # container's main process and receives signals directly. exec_as_user uses
    # setpriv, which needs CAP_SETUID/CAP_SETGID (the same two capabilities the
    # FreeUnit master uses to drop its workers).
    exec_as_user "$APPLICATION_USER" "$APPLICATION_GROUP" \
        supercronic "$@"
}
