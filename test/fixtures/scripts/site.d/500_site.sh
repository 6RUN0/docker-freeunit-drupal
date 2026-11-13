#!/bin/sh
#
# A site script between the Unit and the upgrade scripts of the image, on the
# public library.

set -eu

. /usr/local/lib/freeunit-drupal/lib.sh

freeunit_drupal_log_info "site script 500 sourced lib.sh"
