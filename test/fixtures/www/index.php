<?php

// Minimal app used by the smoke test: the marker proves the PHP module loaded
// and actually served a request through the freeunit-drupal image.
echo 'freeunit-drupal-smoke-ok php=' . PHP_VERSION;

// Report the effective user the worker runs as, so the smoke test can assert
// FreeUnit dropped the PHP worker to the configured app user (freeunit) and not
// root -- the same privilege-drop property the cron role checks. Guarded by
// function_exists so a build without ext-posix still emits the marker above:
// the assertion is then skipped host-side, never failing the web probe.
if (function_exists('posix_geteuid')) {
    $uid = posix_geteuid();
    $name = function_exists('posix_getpwuid') ? (posix_getpwuid($uid)['name'] ?? '') : '';
    echo ' worker-user=' . ($name !== '' ? $name : $uid);
}
