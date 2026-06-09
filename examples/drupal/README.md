# Example: full Drupal stack (web + cron + database)

This example shows a realistic production-style deployment of Drupal using a
single `freeunit-drupal` image running in two roles, combined with a MariaDB
database.

**The Drupal application code is NOT baked into the image.** The image provides
only the runtime (Unit, PHP, Composer, supercronic). Your code is mounted at
`/www` via a volume -- either a named Docker volume seeded with your project,
or a bind mount pointing at your checked-out source tree. Drush is not
installed globally; use the project-local `vendor/bin/drush` from your
Composer project.

## Run

```bash
docker compose up        # uses freeunit-drupal:trixie-php8.4 (pull or build)
```

To build the image locally from the repository root instead of pulling:

```bash
docker compose up --build
```

Open <http://localhost:8080/> after Unit has started.

## How the two roles work

Both `web` and `cron` run the **same image**. The only difference is the
command:

| Service | Command | What starts |
|---------|---------|-------------|
| `web`   | *(default)* | Unit web server (PHP app on port 8080) |
| `cron`  | `supercronic` | Cron runner via the `handle_supercronic` entrypoint hook |

The `cron` container never starts Unit. The entrypoint hook intercepts the
`supercronic` command, calls `run_entrypoint_scripts` (the same init hook the
web role uses), then execs `supercronic` as the app user via `setpriv`. Both
roles share the same security hardening:

```yaml
cap_drop: [ALL]
cap_add:  [SETUID, SETGID]
security_opt: [no-new-privileges:true]
```

`SETUID`/`SETGID` are required in both roles: Unit needs them to drop each PHP
worker to the `unit` user; the cron hook needs them to drop `supercronic`
itself to `unit` via `setpriv`.

## Placing your Drupal code

The compose file uses a named volume `drupal_code` as a placeholder. Replace
it with a bind mount pointing at your project root (the directory containing
`composer.json`):

```yaml
volumes:
  drupal_code:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /path/to/your/drupal
```

Set `DRUPAL_ROOT` in `environment:` to the docroot (the directory containing
`index.php`). For a `drupal/recommended-project` Composer layout that is
`/www/web`.

## Files

- [`docker-compose.yml`](docker-compose.yml) -- three services: `web`, `cron`,
  `db`. Both application services use the same image; the role is selected by
  the command.
- [`config.json`](config.json) -- Unit application config: listener on 8080,
  static file serving with PHP fallback via `index.php`, PHP worker running as
  `unit:unit`. Mounted into `web` at `/docker-entrypoint.d/config.json`.
- [`crontab`](crontab) -- supercronic crontab: triggers Drupal cron via
  `curl` on the `DRUPAL_CRON_URL` endpoint every 15 minutes (with a
  commented alternative using project-local `vendor/bin/drush`). Mounted
  into `cron` at `/etc/supercronic/crontab`, overriding the image default.
