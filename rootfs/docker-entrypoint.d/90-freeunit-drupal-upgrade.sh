#!/bin/sh
#
# When FREEUNIT_DRUPAL_UPGRADE=1: wait for the database, then, on an installed
# site, drush cr, updb and cr. A site that is not installed yet is skipped, so
# the first start before `drush site:install` does not fail. Meant for one
# role only (cron), as the process user: two roles would run updb twice.

set -eu

. /usr/local/lib/freeunit-drupal/lib.sh

freeunit_drupal_flag_enabled FREEUNIT_DRUPAL_UPGRADE || exit 0

# The web role runs the scripts inside its configuration round, with a
# temporary Unit daemon on the control socket.
if [ -S "$UNIT_CONTROL_SOCKET" ]; then
    freeunit_drupal_log_warn "upgrade runs in the web role; enable it in one role only"
fi

freeunit_drupal_wait_for_db

fd_bootstrap=$( (freeunit_drupal_drush status --field=bootstrap 2>/dev/null || true) | tr -d '[:space:]')
if [ "$fd_bootstrap" != Successful ]; then
    freeunit_drupal_log_notice "Drupal not installed, skipping upgrade"
    exit 0
fi

for fd_step in cr 'updb --yes' cr; do
    freeunit_drupal_log_info "drush $fd_step"
    # shellcheck disable=SC2086 # the step splits into the drush arguments
    freeunit_drupal_drush $fd_step || freeunit_drupal_die "drush $fd_step failed"
done
