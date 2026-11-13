# Examples

Each subdirectory is a self-contained example built on the `freeunit-drupal`
image; its README says how to start it.

- [`drupal/`](drupal/) -- a starter for a new Drupal site, built into its own
  image `FROM freeunit-drupal`: unit and cron from that image, Varnish with
  BAN by cache tags, MariaDB, Redis and, under the compose profile `search`,
  OpenSearch, all under the hardening fragment of the image. It is also the
  end-to-end test of the image (`make test-example`, CI).
