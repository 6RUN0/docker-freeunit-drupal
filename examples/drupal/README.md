# Example: a Drupal site built on freeunit-drupal

A starter project for a new Drupal site and the end-to-end test of the image.
The site is built into its own image `FROM ghcr.io/6run0/freeunit-drupal`:
code, settings, recipes and crontab are in the image, the data are volumes.
Copy the directory into a new repository and own the copy: nothing here is
part of the image contract (README of the image, "Stability"), and the image
does not promise compatibility with a site's copy of the VCL or the compose
file.

| Service | Image | Role |
|---------|-------|------|
| `unit` | the site image | FreeUnit with the Drupal application |
| `cron` | the site image | supercronic: `drush cron` every minute, `/tmp` cleanup daily; runs the upgrade on start |
| `varnish` | `varnish:9.0.4-5` | the only published port, `127.0.0.1:${SITE_HTTP_PORT:-8080}` |
| `mariadb` | `mariadb:11.8.9` | database |
| `redis` | `redis:8.10.3-trixie` | cache backend, password required |
| `opensearch` | `opensearchproject/opensearch:2.19.7` | profile `search` only |

The project: `drupal/recommended-project` 11.4.12 with `drush/drush`,
`purge`, `varnish_purge`, `redis`, `search_api` and `search_api_opensearch`
(`composer.json`, `composer.lock`).

## Requirements

- Docker Engine on amd64 (the image is amd64 only) with Docker Compose 2.24 or
  later; `tests/e2e.override.yml` uses `!reset`.
- No PHP or Composer on the host: Composer runs in the image build.

## Start

The `FROM` tag `0.5.0-php8.4` exists once freeunit-drupal 0.5.0 is released.
On the `develop` branch of the image repository build and test against the
local image instead: `make test-example` from the repository root
([Test](#test)).

1. Copy the directory and create `.env`, the secrets and the `/tmp` dir:

   ```sh
   cp .env.example .env
   mkdir -m 0700 secrets
   for name in db_password db_root_password redis_password hash_salt; do
     od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "secrets/$name"
   done
   chmod 0444 secrets/*
   mkdir -p data/tmp
   docker run --rm --user 0:0 -v "$PWD/data/tmp:/d" --entrypoint chown \
     ghcr.io/6run0/freeunit-drupal:0.5.0-php8.4 65532:65532 /d
   ```

   A missing `data/tmp` would be created `root:root` by Docker and the start
   fails (`/tmp is not writable`). The secrets are read by three uids (999 for
   MariaDB and Redis, 65532 for unit and cron), hence `0444` in a `0700`
   directory; see [Secrets](#secrets) for production.

2. Build and start, then install Drupal and apply the stack recipe:

   ```sh
   docker compose up -d --build --wait
   docker compose exec cron drush site:install minimal --yes
   docker compose exec cron drush recipe /www/recipes/freeunit_drupal_stack
   ```

3. Switch the cache to Redis: set `SITE_REDIS_ENABLE=1` in `.env`, then
   `docker compose up -d --wait`. The redis module must be installed (step 2)
   before the flag is set: its services do not exist before.

4. Open <http://localhost:8080/>. Varnish strips the port from `Host`, and
   `localhost` is what `SITE_TRUSTED_HOST_PATTERNS` (`^localhost$`) and the
   `Cache-Host` of the purger expect; `http://127.0.0.1:8080/` gets 400 from
   Drupal ("The provided host name is not valid for this server").

Before the installation Unit answers `/` with 302 to the installer, which the
built-in Unit template of the image refuses with 404: install with drush.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | the site image: dependencies from the lock in one layer, the site files and the autoloader (offline) in the next; `web/sites/default/files` and `private` owned by 65532 |
| `.dockerignore` | allowlist of the build context |
| `composer.json`, `composer.lock` | the Drupal project |
| `web/sites/default/settings.php` | settings that are the same in every deployment |
| `web/sites/default/settings.container.php` | settings from the environment (`SITE_*`) |
| `web/sites/default/services.yml` | `http.response.debug_cacheability_headers: true`, for the bans |
| `config/sync/` | the config sync directory, empty |
| `recipes/freeunit_drupal_stack/` | purge with the Varnish purger, Redis, `file`, page cache 1 hour |
| `recipes/freeunit_drupal_search/` | Search API with an OpenSearch server and a `content` index |
| `crontab` | the crontab baked into `/etc/supercronic/crontab` |
| `docker-compose.yml` | the stack |
| `docker-compose.hardening.yml` | copy of the hardening fragment of the image, byte for byte |
| `varnish/default.vcl`, `varnish/common.vcl` | probe and backend; the shared VCL |
| `.env.example` | the variables of the compose file, no secrets |
| `.gitignore` | allowlist: the site's own files, not `vendor/`, `web/core/`, contrib modules and recipes, or `files/`; own recipes are `recipes/freeunit_drupal_*` (rename the pattern here and in `.dockerignore` with them) |
| `tests/e2e.sh`, `tests/e2e.override.yml` | the end-to-end test |

## Image

The `Dockerfile` sets `FREEUNIT_DRUPAL_UNIT_CONFIG=1` (the built-in Unit
template of the image) and `FREEUNIT_DRUPAL_WRITABLE_DIRS`, and puts
`/www/vendor/bin` on `PATH`, so `docker compose exec cron drush ...` works.
The code is root-owned and read-only; the two data directories are created
for 65532. With another `FREEUNIT_DRUPAL_RUN_UID`, change the `install -d -o`
line and recreate the volumes `files` and `private`: a volume keeps the owner
it was created with, and `10-freeunit-drupal-writable-dirs.sh` stops the start
(`... is not a directory writable for uid ...`).

`cron` runs the image script `90-freeunit-drupal-upgrade.sh`
(`FREEUNIT_DRUPAL_UPGRADE=1`): on every start it waits for the database, and
on an installed site runs `drush cr`, `updb`, `cr`. A failed step stops the
container; with `restart: unless-stopped` it restarts.

## Settings

`settings.container.php` reads the environment with `getenv()`; FreeUnit
workers and drush see the container environment there, `$_ENV` and
`$_SERVER` do not carry it. A missing value throws: the upgrade in `cron`
stops the start with the message, and Unit answers 500.

| Variable | Default | Meaning |
|----------|---------|---------|
| `SITE_DB_HOST`, `SITE_DB_NAME`, `SITE_DB_USER` | required | database |
| `SITE_DB_PORT` | `3306` | database port |
| `SITE_DB_PASSWORD_FILE` | required | file with the database password |
| `SITE_HASH_SALT_FILE` | required | file with the hash salt; empty or unreadable throws `SITE_HASH_SALT_FILE: ...` |
| `SITE_TRUSTED_HOST_PATTERNS` | `^localhost$` | `trusted_host_patterns`, separated by whitespace; from `.env` (single-quoted there: `$` is interpolated otherwise) |
| `SITE_REVERSE_PROXY_HOST` | `varnish` | name of the reverse proxy, resolved on every web request |
| `SITE_REDIS_ENABLE` | `0` | `1`: cache backend Redis; anything but empty, `0` or `1` throws |
| `SITE_REDIS_HOST`, `SITE_REDIS_PORT` | required with `SITE_REDIS_ENABLE=1`, `6379` | Redis |
| `SITE_REDIS_PASSWORD_FILE` | required with `SITE_REDIS_ENABLE=1` | file with the Redis password |

`.env` also sets `SITE_HOSTNAME` (`localhost`; `DRUSH_OPTIONS_URI` is
`http://$SITE_HOSTNAME`, and it is the `Host` of `freeunit-drupal-healthcheck`)
and `SITE_REDIS_MAXMEMORY` (`256mb`, `maxmemory` of Redis with
`allkeys-lru`: the cache never outgrows it).

In `docker-compose.yml` the `*_FILE` variables of the containers point to
`/run/secrets/<name>`; in `.env` the same names are the host files the
compose `secrets:` read. `settings.php` is complete, so `drush
site:install` leaves it as it is: the database, the salt and an existing
`config_sync_directory` are set.

The reverse proxy (web requests only; drush takes no requests and does not
depend on Varnish): `reverse_proxy_addresses` are the IPv4 addresses of
`varnish` from `gethostbynamel()`, and only `X-Forwarded-For` is trusted. A
name that does not resolve throws (`reverse proxy host "varnish" does not
resolve`) instead of making the Varnish address the address of every visitor.
So the health of `unit` depends on the name `varnish` resolving: while
`varnish` is stopped or recreated, every request to `unit`, its healthcheck
included, is a 500. `unit` therefore starts after `varnish`
(`depends_on: varnish: condition: service_started`); do not make `varnish`
wait for a healthy `unit`, that would never start.
The compose networks have no IPv6; with `enable_ipv6` add the addresses from
`dns_get_record($host, DNS_AAAA)`.

## Varnish

`varnishd` runs with an explicit command, so the image's PROXY listener on
8443 does not exist: `http` on 80 and `purge` on 8081, as uid 1000, read-only,
no capabilities, its working directory a tmpfs with `exec` (the compiled VCL
is loaded from there). The VCL is mounted as a directory: an editor that
saves through a rename does not leave the container on the old file. Restart
`varnish` after editing it.

There is no front proxy, so the VCL trusts no client header: it drops
`X-Real-IP`, `X-Forwarded-Host`, `X-Forwarded-Port`, `X-Forwarded-Proto` and
`Forwarded`, sets `X-Forwarded-For` to the client address, and strips the
port from `Host` (Drupal checks it against `trusted_host_patterns`).

BAN, sent by the purger with `Cache-Tags` (`tag1|tag2`) and `Cache-Host`:

| Request | Answer |
|---------|--------|
| BAN on the `http` listener (80) | 405 |
| any other method on the `purge` listener (8081), or a client outside the private networks | 405 |
| `Cache-Tags` not `^[A-Za-z0-9_.:-]+(\|[A-Za-z0-9_.:-]+)*$` (an empty alternative would ban the whole host), `Cache-Host` not `^[A-Za-z0-9.-]+$` | 400 |
| backend sick, which is what the probe sees: Unit not answering, not a Drupal error (Varnish serves stale objects; the purge queue retries) | 403 |
| otherwise: ban of the objects of that host whose `X-Drupal-Cache-Tags` hold one of the tags | 200 |

A tag matches only a whole tag of the object, literally: the VCL escapes its
dots and anchors it at the spaces between tags, so `config:block` or
`config:block.list` leave an object tagged `config:block_list` cached.

Pages are cached for the `max-age` Drupal sends (the stack recipe sets the
page cache to 1 hour), static files found (200) for 7 days, a 5xx for 10 s as
hit-for-miss; grace is 24 h. `X-Cache-Status` tells `HIT` from `MISS`.

The backend is a `vmod_reqwest` client (`varnish/default.vcl`) on
`http://unit:8080`, which resolves `unit` per connection. A plain VCL
backend resolves the name once, when the VCL loads: a `unit` recreated by a
deploy, or started after another container took its address on `edge`,
would leave Varnish on the old address (backend sick, or traffic to that
other container) until Varnish restarts, and restarting it on every deploy
would empty the cache and answer 503 until two probes pass. With the client
Varnish keeps running and keeps its cache while `unit` changes address; the
e2e test moves `unit` to another address and checks it. The client follows
no redirect and leaves the encodings to Varnish. It has no limit on the
whole request: the only one it offers would include the body and cut long
uploads and downloads; PHP is bounded by Unit (`limits.timeout`, 60 s), the
connection by `connect_timeout` (5 s). Its trade-off is the probe:
it sends `Host: unit:8080` and cannot send another, which
`trusted_host_patterns` rejects, so it asks the static
`/core/misc/drupal.js` every 5 s (window 3, threshold 2). The probe sees Unit
down, not a Drupal error: a 500 of PHP is a hit-for-miss for 10 s, and an
expired object in grace stays (a failed background fetch is abandoned).

### Behind a TLS front

The example serves HTTP on `127.0.0.1`. Behind a TLS proxy:

- add an ACL with the front's address to the VCL and, for requests from it
  only, set `X-Forwarded-For` from its `X-Real-IP` and keep its
  `X-Forwarded-Proto`; drop them from everyone else as now;
- add `| Request::HEADER_X_FORWARDED_PROTO` to
  `reverse_proxy_trusted_headers`, otherwise Drupal builds `http://` links
  and the session cookie lacks `Secure`;
- set `SITE_HOSTNAME` and `SITE_TRUSTED_HOST_PATTERNS` in `.env` and the
  `Cache-Host` of the purger (`varnish_purger.settings.5f0d3c9a71`,
  `localhost` in the recipe) to the site's host name.

## Networks

`edge`: `varnish`, `unit`, `cron`. `data` (`internal: true`, no route out):
`unit`, `cron`, `mariadb`, `redis`, `opensearch`. Only `varnish` publishes a
port, on `127.0.0.1`. Do not publish 3306, 6379, 9200 or the purge port 8081;
to debug, publish on `127.0.0.1:` only. The networks have no fixed subnet, so
two projects on one host do not collide.

## Secrets

Compose `secrets:` with `file:` from `.env`, mounted at `/run/secrets/<name>`
(under the tmpfs `/run` of the fragment for unit and cron):

| Service | Secrets |
|---------|---------|
| `unit`, `cron` | `db_password`, `redis_password`, `hash_salt` |
| `mariadb` | `db_password`, `db_root_password` (`MARIADB_ROOT_HOST=localhost`) |
| `redis` | `redis_password`, written into `/data/redis.conf` (tmpfs, 0600) for `redis-server`, never in argv; `redis-server` is PID 1 and stops on SIGTERM |
| `varnish`, `opensearch` | none |

A file secret is a bind mount: the container sees the owner and mode of the
host file, `uid`, `gid` and `mode` of the long syntax are not applied. In
production either keep one copy per consumer, owned by its uid, `0400`
(`db_password` once for 999, once for 65532), or give `mariadb`, `unit` and
`cron` a common group with `group_add` (for example 10001) and make the
files `root:10001 0440`. A group and `0440` without `group_add` does not work.

## Recipes

`freeunit_drupal_stack` installs `file`, `purge`, `purge_tokens`,
`purge_queuer_coretags`, `purge_processor_cron`, `varnish_purger` and
`redis`, sets the page cache max age to 1 hour, creates the purger
`varnish_purger.settings.5f0d3c9a71` (BAN to `varnish:8081`, tag
invalidation, `Cache-Tags: [invalidations:separated_pipe]`,
`Cache-Host: localhost`) and writes `purge.plugins` with that purger and the
processors `cron` and `drush_purge_queue_work`. `purge.plugins` comes from the
recipe's `config/`: it does not exist after the modules are installed, so a
config action cannot update it. Tag invalidations are queued and sent by
cron or by `drush p:queue-work`.

`freeunit_drupal_search` (with `--profile search`) applies the core recipe
`page_content_type`, installs `search_api` and `search_api_opensearch`, and
creates the server `opensearch` (`http://opensearch:9200`) and the index
`content` (node titles):

```sh
docker compose --profile search up -d --wait
docker compose exec cron drush recipe /www/recipes/freeunit_drupal_search
docker compose exec cron drush search-api:index content
```

OpenSearch runs with the security plugin and the demo configuration
disabled, reachable only on `data`. Its root filesystem is not read-only: it
writes its keystore into `config/` at start, which a tmpfs over that directory
would hide together with the configuration.

## Pins

- The site image: `FROM ghcr.io/6run0/freeunit-drupal:0.5.0-php8.4`, an
  immutable tag by the release policy of the image. A real site also pins the
  digest (`...:0.5.0-php8.4@sha256:...`): the tag is only as safe as the write
  access to the registry.
- Other images: tag and index digest.
- Composer: the lock. Update it with the Composer of the image, as your uid:

  ```sh
  docker run --rm --user "$(id -u):$(id -g)" -e COMPOSER_HOME=/tmp/composer \
    -v "$PWD:/app" -w /app --entrypoint composer \
    ghcr.io/6run0/freeunit-drupal:0.5.0-php8.4 update --no-install
  ```

## Test

`tests/e2e.sh <freeunit-drupal image>` builds the site image with its `FROM`
replaced by the given image (the layers of that image must be the first layers
of the site image, else `Bail out!`), runs the stack in its own compose project
`freeunit-drupal-e2e-<pid>` without published ports, and prints TAP: start
under the fragment, secrets, the scripts of the image before and after the
installation, `site:install` with a read-only `settings.php`, the recipe,
Redis with and without the password, Varnish keeping its cache while unit is
recreated, hits and misses, `Host` with the published port, the purge from
the queue to the ban, its selectivity on a tagged page, the BAN refusals, the
headers Varnish sends to Unit (`varnishlog`) and the client IP and `Location`
Drupal derives from forged forwarding headers, managed files, PHP under
`sites/default/files`, a 1 MB POST, cron, the hardening of the services, a
backend outage (grace past the TTL, then unit back on another address), the
refusal of a foreign uid and of an empty salt, and the hardening check of the
image. The project, its volumes, the site image and the
generated secrets are removed on exit. About 6 minutes on a warm cache;
`--search` adds OpenSearch.

From the repository root:

```sh
make test-example                     # builds freeunit-drupal:local-php8.4 first
make test-example E2E_ARGS=--search
```

`E2E_AUDIT=report` turns a `composer audit --locked` finding into a TODO
test instead of a failure; `E2E_BUILD_EXTRA` adds flags to the image build.

## Accepted risks

- `X-Drupal-Cache-Tags` and the other cacheability headers are sent by Drupal
  and stripped by Varnish; a client that reaches `unit` directly sees them.
  `unit` publishes no port.
- Any container on `edge` can send BAN to `varnish:8081`.
- OpenSearch writes its root filesystem (keystore).
- The purger sends `Cache-Host: localhost`; a site changes it with its host
  name.
