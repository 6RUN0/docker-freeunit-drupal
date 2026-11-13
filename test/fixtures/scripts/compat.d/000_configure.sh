#!/bin/sh -e
#
# A 0.4.0-style site script: renders its own Unit configuration into the
# generated dir and its own /run/msmtprc, knowing nothing of the image scripts.

sed -e 's!%%APPLICATION_DIR%%!/www!g' /fixtures/compat/unit-config.template \
    >"$ENTRYPOINT_GENERATED_DIR/unit-config.json"
(umask 077 && cp /fixtures/compat/msmtprc /run/msmtprc)
