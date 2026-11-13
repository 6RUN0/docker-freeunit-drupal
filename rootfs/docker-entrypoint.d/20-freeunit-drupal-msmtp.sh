#!/bin/sh
#
# When FREEUNIT_DRUPAL_SMTP_HOST is set, writes /run/msmtprc (0600, first line
# "# freeunit-drupal") from FREEUNIT_DRUPAL_MSMTP_TEMPLATE or from the built-in
# account. freeunit-drupal-sendmail, the sendmail_path of PHP cli and embed,
# passes it to msmtp. A /run/msmtprc without the first line belongs to an
# earlier script and stops the start; one with it is from a previous start and
# is rewritten.

set -eu

. /usr/local/lib/freeunit-drupal/lib.sh

[ -n "${FREEUNIT_DRUPAL_SMTP_HOST:-}" ] || exit 0

fd_out=/run/msmtprc
fd_marker='# freeunit-drupal'

_fd_require_env FREEUNIT_DRUPAL_SMTP_FROM
: "${FREEUNIT_DRUPAL_SMTP_PORT:=25}"
: "${FREEUNIT_DRUPAL_SMTP_TLS:=off}"
: "${FREEUNIT_DRUPAL_SMTP_AUTH:=off}"
export FREEUNIT_DRUPAL_SMTP_PORT FREEUNIT_DRUPAL_SMTP_TLS FREEUNIT_DRUPAL_SMTP_AUTH

for fd_name in FREEUNIT_DRUPAL_SMTP_TLS FREEUNIT_DRUPAL_SMTP_AUTH; do
    fd_value=$(_fd_value_of "$fd_name")
    case "$fd_value" in
        on | off) ;;
        *) freeunit_drupal_die "$fd_name must be on or off, got '$fd_value'" ;;
    esac
done
case "$FREEUNIT_DRUPAL_SMTP_PORT" in
    '' | *[!0-9]*) freeunit_drupal_die "FREEUNIT_DRUPAL_SMTP_PORT must be a port number, got '$FREEUNIT_DRUPAL_SMTP_PORT'" ;;
esac

if [ "$FREEUNIT_DRUPAL_SMTP_AUTH" = on ]; then
    # Without TLS the password would cross the network in clear text.
    [ "$FREEUNIT_DRUPAL_SMTP_TLS" = on ] \
        || freeunit_drupal_die "FREEUNIT_DRUPAL_SMTP_AUTH=on needs FREEUNIT_DRUPAL_SMTP_TLS=on"
    _fd_require_env FREEUNIT_DRUPAL_SMTP_USER FREEUNIT_DRUPAL_SMTP_PASSWORD_FILE
    fd_password_file=$FREEUNIT_DRUPAL_SMTP_PASSWORD_FILE
    # It lands in passwordeval "cat '<path>'": a quote, a backslash or a
    # newline would break out of the quoting or add a configuration line.
    case "$fd_password_file" in
        *"'"* | *'"'* | *"\\"* | *"
"*) freeunit_drupal_die "FREEUNIT_DRUPAL_SMTP_PASSWORD_FILE must not contain a quote, a backslash or a newline" ;;
        /*) ;;
        *) freeunit_drupal_die "FREEUNIT_DRUPAL_SMTP_PASSWORD_FILE must be an absolute path, got '$fd_password_file'" ;;
    esac
    [ -f "$fd_password_file" ] && [ -r "$fd_password_file" ] \
        || freeunit_drupal_die "FREEUNIT_DRUPAL_SMTP_PASSWORD_FILE is not a readable file: $fd_password_file"
fi

if [ -e "$fd_out" ]; then
    fd_first=$(head -n 1 "$fd_out" 2>/dev/null || true)
    [ "$fd_first" = "$fd_marker" ] \
        || freeunit_drupal_die "$fd_out was written by an earlier script; unset FREEUNIT_DRUPAL_SMTP_HOST or drop that script"
fi

fd_nl='
'
fd_tmp=$fd_out.tmp.$$
if [ -n "${FREEUNIT_DRUPAL_MSMTP_TEMPLATE:-}" ]; then
    fd_body=$fd_out.body.$$
    _fd_render_template "$FREEUNIT_DRUPAL_MSMTP_TEMPLATE" "$fd_body" text
    if ! (umask 077 && { printf '%s\n' "$fd_marker" && cat "$fd_body"; } >"$fd_tmp"); then
        rm -f "$fd_body" "$fd_tmp"
        freeunit_drupal_die "cannot write $fd_tmp as uid $(id -u)"
    fi
    rm -f "$fd_body"
else
    for fd_name in FREEUNIT_DRUPAL_SMTP_HOST FREEUNIT_DRUPAL_SMTP_FROM FREEUNIT_DRUPAL_SMTP_USER; do
        case "$(_fd_value_of "$fd_name")" in
            *"$fd_nl"*) freeunit_drupal_die "$fd_name must not contain a newline" ;;
        esac
    done
    if ! (
        umask 077
        {
            printf '%s\n' "$fd_marker" defaults 'logfile -' 'account default'
            printf 'host %s\nport %s\nfrom %s\n' "$FREEUNIT_DRUPAL_SMTP_HOST" \
                "$FREEUNIT_DRUPAL_SMTP_PORT" "$FREEUNIT_DRUPAL_SMTP_FROM"
            if [ "$FREEUNIT_DRUPAL_SMTP_TLS" = on ]; then
                printf '%s\n' 'tls on' 'tls_trust_file system'
            else
                printf '%s\n' 'tls off'
            fi
            if [ "$FREEUNIT_DRUPAL_SMTP_AUTH" = on ]; then
                printf 'auth on\nuser %s\npasswordeval "cat '\''%s'\''"\n' \
                    "$FREEUNIT_DRUPAL_SMTP_USER" "$fd_password_file"
            else
                printf '%s\n' 'auth off'
            fi
        } >"$fd_tmp"
    ); then
        rm -f "$fd_tmp"
        freeunit_drupal_die "cannot write $fd_tmp as uid $(id -u)"
    fi
fi
mv -f "$fd_tmp" "$fd_out" || freeunit_drupal_die "cannot write $fd_out as uid $(id -u)"
