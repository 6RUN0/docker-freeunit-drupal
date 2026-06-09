<?php

// Minimal app used by the smoke test: the marker proves the PHP module loaded
// and actually served a request through the freeunit-drupal image.
echo 'freeunit-drupal-smoke-ok php=' . PHP_VERSION;
