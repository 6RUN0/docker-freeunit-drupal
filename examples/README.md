# Examples

Each subdirectory is a self-contained example built on the `freeunit-drupal`
image. Pick one, `cd` into it, and `docker compose up`.

- [`drupal/`](drupal/) -- a full Drupal stack: one image running in two roles
  (web server and cron runner) plus a MariaDB database, selected per container
  by the command. Bind-mount your Drupal code; nothing is baked in.
