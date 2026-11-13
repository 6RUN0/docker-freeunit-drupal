# Drupal runtime image based on freeunit-php

[English](README.md) · [Русский](README.ru.md) — see [CHANGELOG.md](CHANGELOG.md)
for release history.

This repo builds Docker images that extend
[`ghcr.io/6run0/freeunit-php`](https://github.com/6RUN0/docker-freeunit-php)
(FreeUnit — a fork of NGINX Unit — with an embedded PHP module) with the
toolchain a Drupal site needs at runtime.

What this image adds on top of the base:

- **Composer** — downloaded as a `.phar` and verified against the pinned
  [Composer maintainer GPG key](https://getcomposer.org/download/) (key
  `161DFBE342889F01DDAC4E61CBB3D576F2A0946F`).
- **supercronic** — a crontab-compatible foreground cron runner, pinned by
  version and verified by SHA256, wired in as a second launch mode via the
  base entrypoint hook system.
- **APT packages** for a Drupal runtime: `git` + `openssh-client` (pull and
  deploy config and code over SSH-authenticated git), `mariadb-client` + `less`
  (inspect the database, e.g. `SELECT ... \G` through a pager), `msmtp` (the
  SMTP client behind PHP's `mail()`, see [Mail](#mail-msmtp)), `patch` (so
  `cweagans/composer-patches` can apply drupal.org patches during
  `composer install`), and `unzip` (Composer archive extraction).

The Drupal application code is **not** baked into the image. It is mounted
or installed by Composer at runtime. This image is the runtime environment,
not the site.

It does carry the generic start-up plumbing of a Drupal site, every part
opt-in: a rendered Unit configuration with Drupal routes, a rendered
`/run/msmtprc`, a writable-dirs check, `drush cr`/`updb`/`cr` on start, a
healthcheck, a `/tmp` cleanup, a compose hardening fragment and a check for it
(see [Drupal entrypoint scripts](#drupal-entrypoint-scripts) and
[Stability](#stability)).

- **Base image:** `ghcr.io/6run0/freeunit-php` 0.4.0 (trixie, amd64), pinned
  by tag and digest
- **User:** the non-root `nonroot` (65532:65532) from the first instruction,
  in both roles; see [Run as non-root](#run-as-non-root)
- **PHP versions:** 8.3, 8.4, 8.5 (one image per PHP line)
- **Distribution:** Debian **trixie**, amd64 only

A single parameterized `Dockerfile` covers the whole matrix via build args;
the `Makefile` builds every variant.

## Pull

Pre-built images are published to the GitHub Container Registry at
`ghcr.io/6run0/freeunit-drupal`. Each release pushes one image per PHP line
(8.3 / 8.4 / 8.5) under several tags:

| Tag pattern | Example | Resolves to |
|-------------|---------|-------------|
| `latest` | `ghcr.io/6run0/freeunit-drupal` | newest release, default PHP (8.4) |
| `<version>` | `:0.4.0` | that repo release, default PHP |
| `<version>-php<X.Y>` | `:0.4.0-php8.4` | a specific release on a PHP line |

```bash
docker pull ghcr.io/6run0/freeunit-drupal:0.4.0-php8.4
```

The `latest` tag floats to the newest release (default PHP). The `<version>`
and `<version>-php<X.Y>` tags are immutable: the release workflow refuses to
overwrite one that exists. Pin a deployment by digest
(`:0.4.0-php8.4@sha256:...`). Releases up to 0.3.5 also published a
`<base-tag>-php<X.Y>` tag mirroring the substrate (e.g. `:trixie-1.37.1-php8.4`,
root image); 0.4.0 publishes none and leaves the existing ones untouched.

## Build

The Makefile is the reproducible way: it pins the base by digest.

```bash
make                                        # build all PHP versions (8.3, 8.4, 8.5)
make php8.3                                 # build one variant -> freeunit-drupal:local-php8.3
make latest                                 # build the default PHP (8.4) and tag :latest
make test                                   # build the default PHP and run the smoke test
make lint                                   # run all installed linters
make scan                                   # CVE-scan the default image (trivy/grype if installed)
make BASE_TAG=trixie BASE_DIGEST= php8.4    # track the floating substrate
```

`local-php<X.Y>` is a local build tag, never published.

A plain `docker build` pulls the base by tag only (no digest):

```bash
docker build -t freeunit-drupal .                                  # base 0.4.0, php8.4
docker build --build-arg PHP_VER=8.3 -t freeunit-drupal:8.3 .
docker build --build-arg BASE_TAG=trixie -t freeunit-drupal .     # floating suite tag
```

The per-release defaults (`BASE_IMAGE`, `BASE_TAG`, `PHP_VER`) and the base
digest of every PHP line (`BASE_DIGEST_PHP83`, `BASE_DIGEST_PHP84`,
`BASE_DIGEST_PHP85`) live in the `Dockerfile` ARGs. The `Makefile` reads them
from there and passes the digest of the line it builds as `BASE_DIGEST`; an
empty table entry stops the build. Overriding `BASE_IMAGE` or `BASE_TAG`
needs `BASE_DIGEST` too (empty = by tag only), else `make` stops: the table
digest would win over the tag. A base bump is `BASE_TAG` plus the three
digests, all in the `Dockerfile`; read each one with
`docker buildx imagetools inspect ghcr.io/6run0/freeunit-php:<version>-php<X.Y>`.
Two more assets are pinned in the `Dockerfile` ARGs: `supercronic` (version +
SHA256) and Composer (`COMPOSER_VERSION`; the phar is GPG-verified on every
build - pass an empty value to track the latest release instead).

A derived image runs its `RUN` steps as root and switches back at the end
(hadolint rejects a non-numeric `USER`):

```dockerfile
FROM ghcr.io/6run0/freeunit-drupal:0.4.0-php8.4@sha256:...
USER 0:0
RUN apt-get update && apt-get install -y --no-install-recommends ...
USER 65532:65532
```

## Run

### Web role

The primary use: run a Drupal site under the FreeUnit web server.

```bash
# /tmp is a host dir owned by the process uid; a missing ./tmp would be
# created root:root by Docker and the start fails ("/tmp is not writable").
sudo install -d -o 65532 -g 65532 -m 0700 tmp
docker run -d --name drupal \
  -p 8080:8080 \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /run:size=16m,uid=65532,gid=65532,mode=0700 \
  -v "$PWD/tmp:/tmp" \
  -v "$PWD/web:/www:ro" \
  -v "$PWD/config.json:/docker-entrypoint.d/config.json:ro" \
  ghcr.io/6run0/freeunit-drupal:0.4.0-php8.4
```

On every start with an empty `/run` the base entrypoint applies everything in
`/docker-entrypoint.d/` (scripts, certificates, FreeUnit config) and then starts
the FreeUnit daemon in the foreground. The image's own scripts there do nothing
without their variables; mount single files into `/docker-entrypoint.d/`, as
above: a directory mounted over it hides them (see
[Drupal entrypoint scripts](#drupal-entrypoint-scripts)). See the base image documentation for the
full start-up behaviour and the `/docker-entrypoint.d/` conventions.

A minimal FreeUnit `config.json` for Drupal:

```json
{
  "listeners": { "*:8080": { "pass": "applications/drupal" } },
  "applications": {
    "drupal": {
      "type": "php",
      "root": "/www",
      "script": "index.php"
    }
  }
}
```

No `user`/`group` keys: a non-root Unit runs its workers as its own uid and
cannot switch to another user.

### Cron role

Run the same image as a supercronic cron runner alongside the web container,
without a separate image and without overriding the entrypoint.

```bash
docker run -d --name drupal-cron \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /run:size=16m,uid=65532,gid=65532,mode=0700 \
  -v "$PWD/tmp:/tmp" \
  -v "$PWD/crontab:/etc/supercronic/crontab:ro" \
  -e DRUPAL_CRON_URL=http://localhost:8080/cron/YOUR_CRON_KEY \
  ghcr.io/6run0/freeunit-drupal:0.4.0-php8.4 supercronic
```

The shipped crontab is a commented template with no active jobs, so mount your
own (as above) or enable a job in a derived image — see [Default crontab](#default-crontab).

Passing `supercronic` as the container command activates the cron role. The
base entrypoint's `dispatch_handler` recognises it and calls
`handle_supercronic` from the hook at
`/docker-entrypoint-hook.d/supercronic.sh`, which:

1. Runs any operator `*.sh` drop-ins from `/docker-entrypoint.d/` (the same
   convenience the web role provides).
2. `exec`s `supercronic` as the container user (no privilege drop, no
   capability needed), forwarding any arguments you appended after the
   `supercronic` command and adding the default crontab path when you didn't
   pass one (see [Tuning supercronic](#tuning-supercronic)).

#### Default crontab

The image ships `/etc/supercronic/crontab` as a **commented template with no
active jobs** — it documents the schedule syntax and carries two commented
example jobs: project-local Drush (preferred, see the tip below) and the
Drupal HTTP trigger:

```cron
# */5 * * * * curl -fsS -o /dev/null "${DRUPAL_CRON_URL:-http://localhost:8080/cron.php}"
```

So the cron role idles until you enable a job: uncomment one in a downstream
image, or mount your own crontab at the same path:

```bash
-v "$PWD/crontab:/etc/supercronic/crontab:ro"
```

`DRUPAL_CRON_URL` should be the full URL of the Drupal cron endpoint,
including the cron key (e.g.
`http://localhost:8080/cron/YOUR_CRON_KEY`).

> [!TIP]
> When your project ships Drush, prefer running cron through it instead of
> the HTTP trigger — mount the code volume into the cron container and use a
> crontab line like `*/15 * * * * /www/vendor/bin/drush --root=/www/web cron`.
> Drush runs cron in its own PHP CLI process: no cron key to expose, no
> web-server request timeout on long runs, and it keeps working while the
> site is in maintenance mode. The HTTP trigger remains the zero-dependency
> option when the cron container has no code or database access.

supercronic also accepts schedules POSIX cron can't: an optional leading
**seconds** field for sub-minute jobs (`*/30 * * * * *` = every 30 s), an
optional trailing year field, the `@yearly`/`@monthly`/`@weekly`/`@daily`/`@hourly`
macros, and the `L`/`W`/`#` day specifiers. The shipped crontab carries the
full reference in its header comments.

#### Tuning supercronic

Anything you append after the `supercronic` command is forwarded straight to
the runner, so its flags need no image rebuild:

```bash
# Reload the crontab on change (no container restart) and log verbosely
docker run -d --name drupal-cron \
  -v "$PWD/crontab:/etc/supercronic/crontab" \
  ghcr.io/6run0/freeunit-drupal:latest supercronic -inotify -debug
```

When your trailing argument names an existing file it is used as the crontab.
When there is no argument or the trailing one is a flag, the image default
(`/etc/supercronic/crontab`) is appended, so adding a flag still runs the
baked-in crontab. Any other trailing argument (a mistyped path, or the value
of a flag such as `-prometheus-listen-address :9746`) stops the container with
`supercronic crontab not found: ...`; put the crontab path after a flag value.
The hook adds `-no-reap` unless you pass it: tini is PID 1 and reaps orphaned
job processes. Run `supercronic -help` for the full
list (`-inotify`, `-overlapping`, `-split-logs`, `-prometheus-listen-address`, …).

### Entrypoint hook mechanism

The cron role is implemented as an **entrypoint hook** — a `*.sh` file in
`/docker-entrypoint-hook.d/` that defines a `handle_supercronic` function.
The base entrypoint sources every hook there before dispatch, and when the
container command matches, the handler owns the launch (it must `exec` the
final process).

Child images do **not** override `/docker-entrypoint.sh`, so every robustness
and security fix to the base entrypoint is inherited automatically.

Hook authoring rules (enforced by the base dispatcher):

- A hook file must **only define `handle_*` functions** — no top-level side
  effects.
- A hook is portable POSIX sh, sourced with `.` into the image's `/bin/sh`
  (dash): a bash construct is a parse error and the container does not start.
- No `local`: every variable and helper function a hook defines carries the
  `<cmd>_` prefix (`supercronic_crontab`). `UNIT_*`, `ENTRYPOINT_*` and
  `_ep_*` belong to the entrypoint.
- The handler is called left of `||`, so `set -e` is off inside it: check
  every failure that matters explicitly.
- A `handle_<cmd>` **must `exec`** the final process. Returning or exiting
  non-zero is a fatal contract violation.
- Do not shadow base library function names or `UNIT_*` / `ENTRYPOINT_*`
  variables.
- A hook runs as the container user. The dispatcher refuses a hook file that
  user could rewrite (not owned by root, or group/world-writable).

### `/docker-entrypoint.d/` conventions

This image inherits the base entrypoint's `/docker-entrypoint.d/` processing
unchanged. Files are applied in lexical order, by extension:

| Extension | Action |
|-----------|--------|
| `*.sh`    | Executed as the container user. |
| `*.pem`   | Uploaded as a certificate bundle named after the file (minus `.pem`). |
| `*.json`  | `PUT` to the FreeUnit `config` via the control socket. |

Other file types are logged and ignored. A script that renders configuration
at start-up writes it to `$ENTRYPOINT_GENERATED_DIR` (`/run/docker-entrypoint.d`);
its `*.pem` and `*.json` are applied after those of `/docker-entrypoint.d/`.

> Multiple `*.json` are **not** merged: `PUT /config` replaces the whole
> configuration, so only the lexically-last file takes effect (the entrypoint
> warns when more than one is present). Ship a single combined config file.

In the cron role the `*.sh` drop-ins run, but `*.pem` and `*.json` are not
processed (FreeUnit is not started in that role).

### Mail (msmtp)

PHP's `mail()` runs `sendmail_path`. The image sets it for `cli` and `embed`
(`/etc/php/<X.Y>/{cli,embed}/conf.d/05-freeunit-drupal-sendmail.ini`) to
`/usr/local/bin/freeunit-drupal-sendmail -t -i`, and `/usr/sbin/sendmail`
links to the same wrapper. The wrapper runs `msmtp -C /run/msmtprc` when
`/run/msmtprc` exists, and plain `msmtp` (reading `/etc/msmtprc`) otherwise.

Its caller is PHP code, so it accepts only the options PHP `mail()`, Drupal's
`PhpMail` (`-f<addr>`) and Symfony's sendmail transport (`-f<addr>`, `-i`,
`--`) pass: `-t`, `-i`, `-oi`, `-f <addr>` or `-f<addr>`, `-F <name>` or
`-F<name>`, `--`, recipients, and the diagnostics `--pretend` and
`--version`, each as a separate argument. Anything else, a combined `-ti` or
`-tC/x` and an abbreviated `--fil=` included, exits 64 (`EX_USAGE`) before
msmtp runs.

Symfony mailer's `sendmail://default` uses `/usr/sbin/sendmail -bs` by default:
msmtp has no `-bs` mode, and the wrapper refuses it with exit 64. Give the
transport the `-t` form, for example
`sendmail://default?command=/usr/sbin/sendmail%20-t%20-i`.

msmtp keeps no queue: its exit 75 (`EX_TEMPFAIL`, an unresolvable or refusing
relay) means the message is lost, and PHP 8.5 `mail()` would report it as sent.
The wrapper turns 75 into 69 (`EX_UNAVAILABLE`), so `mail()` returns `false`
on every PHP line; other exit codes pass through.

Configure mail in one of three ways:

- set `FREEUNIT_DRUPAL_SMTP_HOST` and `FREEUNIT_DRUPAL_SMTP_FROM`: the image
  writes `/run/msmtprc` at start-up (see
  [Drupal entrypoint scripts](#drupal-entrypoint-scripts));
- render `/run/msmtprc` from a script of your own, as before 0.5.0: the wrapper
  uses it, and `FREEUNIT_DRUPAL_SMTP_HOST` stays unset;
- mount or bake a file at `/etc/msmtprc`, which ships as a **commented template
  with no active settings**:

```bash
-v "$PWD/msmtprc:/etc/msmtprc:ro"
```

A `sendmail_path` of a site ini sorted after `05-` (for example `95-site.ini`
in both `conf.d`) wins over the image's. A `sendmail_path` in the main
`php.ini` of a derived image does not: `conf.d` is read after it.

Keep credentials out of the world-readable `/etc/msmtprc`: the template uses
`passwordeval` to read the password from a mounted secret (e.g.
`/run/secrets/smtp_password`) instead of a plaintext `password` line.

## Drupal entrypoint scripts

The image ships the start-up plumbing a Drupal site needs as four scripts in
`/docker-entrypoint.d/` plus a library. Each is **opt-in**: without its
variable a script writes nothing and changes nothing, so an image upgrade does
not change a site that sets none of them.

| Script | Enabled by | Does |
|--------|------------|------|
| `10-freeunit-drupal-writable-dirs.sh` | `FREEUNIT_DRUPAL_WRITABLE_DIRS` | stops the start unless every listed directory is writable for the process uid; always warns about an unknown `FREEUNIT_DRUPAL_*` name |
| `20-freeunit-drupal-msmtp.sh` | `FREEUNIT_DRUPAL_SMTP_HOST` | writes `/run/msmtprc` (0600) |
| `30-freeunit-drupal-unit-config.sh` | `FREEUNIT_DRUPAL_UNIT_CONFIG=1` | renders the Unit configuration into `$ENTRYPOINT_GENERATED_DIR/freeunit-drupal.json` |
| `90-freeunit-drupal-upgrade.sh` | `FREEUNIT_DRUPAL_UPGRADE=1` | waits for the database, then `drush cr`, `updb --yes`, `cr` on an installed site |

When they run:

- web role: inside the base entrypoint's configuration round, which runs on
  every start with an empty `/run/freeunit` (a tmpfs `/run` is empty on every
  start), with a temporary Unit daemon on the control socket;
- cron role (`supercronic`): on every start, before supercronic;
- any other command (`docker run <image> drush ...`): never.

A script that fails stops the start; the base entrypoint logs
`entrypoint script failed (exit N): /docker-entrypoint.d/<file>` after the
script's own message.

### Order and site scripts

The base runs `/docker-entrypoint.d/*.sh` in byte order (`LC_ALL=C`). `-`
sorts before the digits, so a site script named with three digits and `_`
lands next to the image's two-digit ones:

| Site script | Runs |
|-------------|------|
| `000_` to `099_` | before `10-` |
| `100_` to `199_` | between `10-` and `20-` |
| `200_` to `299_` | between `20-` and `30-` |
| `300_` to `899_` | between `30-` and `90-` |
| `900_` to `999_` | after `90-` |

For example `000_configure.sh` before everything, `500_install.sh` between the
Unit configuration and the upgrade, `999_finish.sh` last. A site script is
COPYed into the derived image with the execute bit
(`COPY --chmod=0755 ...`).

- To turn a script off: leave its variable unset.
- To replace one: unset its variable and ship your own script in the slot.
- To remove one: `RUN rm /docker-entrypoint.d/<file>` in the derived image
  (under `USER 0:0`); the file names are part of [Stability](#stability).
- A directory mounted over `/docker-entrypoint.d` (the
  [Web role](#web-role) example mounts a single file, not a directory) hides
  the image scripts: none of them runs, whatever variables are set. Mail still
  goes through the wrapper, then to `/etc/msmtprc`.

A site script may source the library and use its public functions:

```sh
#!/bin/sh
set -eu
. /usr/local/lib/freeunit-drupal/lib.sh
freeunit_drupal_wait_for_db 120
freeunit_drupal_drush status --field=bootstrap
```

| Function | Does |
|----------|------|
| `freeunit_drupal_log_info`, `_log_notice`, `_log_warn` `<message>` | an entrypoint log line on stderr, prefixed `freeunit-drupal:` |
| `freeunit_drupal_die <message>` | an error line, then `exit 1` |
| `freeunit_drupal_flag_enabled <NAME>` | true for `1`, false for unset, empty or `0`, dies on any other value |
| `freeunit_drupal_drush <args>` | `$FREEUNIT_DRUPAL_PROJECT_DIR/vendor/bin/drush --root=$FREEUNIT_DRUPAL_DOCROOT --no-interaction <args>`; dies when drush is missing |
| `freeunit_drupal_wait_for_db [seconds]` | `drush sql:query 'SELECT 1'` every 2 s, up to `seconds` (default `FREEUNIT_DRUPAL_UPGRADE_DB_WAIT`, else 60), each attempt under `timeout` with the time left; then dies with the last line drush wrote to stderr |

The library sources the base library `/docker-entrypoint-common.sh`; those
functions, and every `_fd_*` name, are implementation details.

### Variables

All names start with `FREEUNIT_DRUPAL_`; the prefixes `FREEUNIT_DRUPAL_`,
`freeunit_drupal_` and `_fd_` are reserved for the image, next to the base's
`UNIT_*`, `ENTRYPOINT_*` and `_ep_*`. A flag (`_UNIT_CONFIG`, `_UPGRADE`)
accepts only unset, empty, `0` (off) or `1` (on); any other value, `yes` or
`true` included, stops the start. `_SMTP_TLS` and `_SMTP_AUTH` accept only
`on` and `off`.

| Variable (`FREEUNIT_DRUPAL_` +) | Default | Purpose |
|---------------------------------|---------|---------|
| `PROJECT_DIR` | `/www` | Composer project root (`vendor/bin/drush`) |
| `DOCROOT` | `$FREEUNIT_DRUPAL_PROJECT_DIR/web` | Drupal docroot: Unit `root` and `share`, drush `--root` |
| `WRITABLE_DIRS` | unset | directories that must be writable, separated by whitespace; a relative path is taken from `PROJECT_DIR` |
| `UNIT_CONFIG` | unset | `1` renders the Unit configuration |
| `UNIT_TEMPLATE` | `/usr/local/share/freeunit-drupal/unit.json.template` | Unit template to render |
| `UNIT_LISTEN` | `*:8080` | listener of the built-in template |
| `UNIT_MAX_BODY_SIZE` | `33554432` | `settings.http.max_body_size`, bytes; a larger request gets 413 from Unit |
| `UNIT_PROCESSES_MAX` / `_SPARE` / `UNIT_PROCESS_IDLE_TIMEOUT` | `8` / `2` / `30` | `processes` of the application |
| `UNIT_LIMITS_TIMEOUT` / `UNIT_LIMITS_REQUESTS` | `60` / `1000` | `limits` of the application |
| `PHP_MEMORY_LIMIT` | `256M` | `memory_limit` |
| `PHP_MAX_EXECUTION_TIME` | `60` | `max_execution_time` |
| `PHP_POST_MAX_SIZE` / `PHP_UPLOAD_MAX_FILESIZE` | `32M` / `32M` | `post_max_size` / `upload_max_filesize` |
| `PHP_TIMEZONE` | `UTC` | `date.timezone` |
| `SMTP_HOST` | unset | SMTP relay; set, it enables `20-` |
| `SMTP_PORT` | `25` | SMTP port |
| `SMTP_FROM` | unset, required with `SMTP_HOST` | envelope sender |
| `SMTP_TLS` | `off` | `on`: TLS with the system CA store |
| `SMTP_AUTH` | `off` | `on`: needs `SMTP_TLS=on`, `SMTP_USER`, `SMTP_PASSWORD_FILE` |
| `SMTP_USER` | unset | SMTP user |
| `SMTP_PASSWORD_FILE` | unset | absolute path of a readable file with the password, without `'`; read by msmtp at send time |
| `MSMTP_TEMPLATE` | unset | own msmtp template instead of the built-in account |
| `UPGRADE` | unset | `1` enables `90-` |
| `UPGRADE_DB_WAIT` | `60` | seconds to wait for the database |
| `HEALTHCHECK_HOST` | unset, required | `Host` of `freeunit-drupal-healthcheck` |
| `HEALTHCHECK_PORT` / `_PATH` / `_PROTO` / `_TIMEOUT` | `8080` / `/` / `https` / `20` | port, path, `X-Forwarded-Proto`, `curl --max-time` seconds |
| `RUN_UID` / `RUN_GID` / `TMP_DIR` | `65532` / `65532` / required | interpolated by the hardening fragment |
| `HARDENING_ENV_FILE` / `_HOST` / `_WRITABLE_DIRS` / `_CRONTAB` | see [Hardening check](#hardening-check) | parameters of the hardening check |

The site URI of drush is the drush variable `DRUSH_OPTIONS_URI`.

There is no variable for `apc.shm_size`: APCu allocates its segment when the
PHP module starts, before Unit applies `options.admin`, so the value would be
reported by `ini_get()` and ignored. Set it in an ini of a derived image
(`/etc/php/<X.Y>/embed/conf.d/`).

### Unit configuration

`30-` renders the template into `$ENTRYPOINT_GENERATED_DIR/freeunit-drupal.json`,
which the base applies after the scripts. `PUT /config` replaces the whole
configuration, so another `*.json` in `/docker-entrypoint.d` or in the generated
dir stops the start (`... was written by an earlier script; drop it or unset
FREEUNIT_DRUPAL_UNIT_CONFIG`); the file `30-` wrote on a previous start does not
count.

The built-in template serves `FREEUNIT_DRUPAL_DOCROOT` on `UNIT_LISTEN` with one
PHP application (`index.php`) and these routes, in order:

1. 404 for source and metadata files: `*.json`, `*.yml`, `*.lock`, `*.md`,
   `*.twig`, `*.txt`, `*.sh`, an extension ending in `sql` (`.sql`, `.mysql`,
   `.pgsql`; a path like `/tags/postgresql` is not one), `*/.*`, `/composer.*`,
   `/vendor/*`, `/core/scripts/*`, `/core/tests/*` and the rest of the list in
   the template. Not for `/robots.txt`, `/.well-known/*` (ACME, `security.txt`)
   and the public files dir `/sites/<site>/files/`, where uploads keep any
   extension (`.txt`, `.csv`, `.json`);
2. 404 under `/sites/<site>/files/` for a hidden name (`.htaccess`), for the
   whole `config_*/` subtree (where the Drupal installer puts the config sync
   directory when `config_sync_directory` is not set), and for the extensions
   Drupal's `.htaccess` denies, never a legitimate upload: `.yml`, `.sql`
   (and `*sql`), `.inc`, `.install`, `.module`, `.profile`, `.engine`,
   `.theme`, `.twig`, `.tpl`, `.xtmpl`, `.make`, `.po`, `.sh`, and backup
   suffixes `~`, `.swp`, `.swo`, `.bak`, `.orig`, `.save`;
3. 404 for `/core/install.php`, `/core/authorize.php`, `/core/rebuild.php` and
   `/update.php`: with a read-only `settings.php` the installer would run
   against the live database; run updates with `drush updb` (`90-`). A site that
   needs `update.php` over HTTP ships its own template;
4. 404 for every other `*.php` except `/index.php`, so PHP under
   `sites/default/files` is never executed;
5. `/index.php` to the application;
6. a static file of the docroot when it exists, else the application.

The access log goes to `/dev/stdout`. There is no `direct` target for other
PHP scripts.

Rendering (`30-` and `MSMTP_TEMPLATE` alike): every `%%NAME%%` with `NAME` an
environment variable is replaced by its value in one pass; a value is never
expanded again. The render stops the start when a `NAME` is not defined
(defined and empty renders empty), when a value holds a newline, and, for the
JSON template, when a value holds `"`, `\` or a control character, or the
result does not parse as JSON. The defaults of the table above are set before
the render; a value from the environment wins. Values end up in the generated
dir and in the Unit configuration, both readable by the uid of PHP: pass
secrets as files, never through a template.

### Mail configuration

`20-` requires `SMTP_FROM` and writes `/run/msmtprc`, 0600, first line
`# freeunit-drupal`, from `MSMTP_TEMPLATE` or from the built-in account
(`host`, `port`, `from`, `tls`, `auth`, `logfile -`). With `SMTP_AUTH=on` the
file carries `passwordeval "cat '<SMTP_PASSWORD_FILE>'"`, never the password.
For implicit TLS on port 465 (`tls_starttls off`) use `MSMTP_TEMPLATE`.

A `/run/msmtprc` without that first line was written by an earlier script and
stops the start (`... unset FREEUNIT_DRUPAL_SMTP_HOST or drop that script`); one
with it is from a previous start on the same `/run` and is rewritten.

`logfile -` writes each delivery, recipient addresses included, to the
container log: personal data whose retention is the site's to decide.

### Upgrade

`90-` with `FREEUNIT_DRUPAL_UPGRADE=1`:

1. in the web role it warns `upgrade runs in the web role; enable it in one role
   only` and goes on; enable it in the cron role only, or both roles run
   `updb`;
2. `freeunit_drupal_wait_for_db`; on timeout the start stops with
   `database not reachable after N s: <last stderr line of drush>`, which names
   the cause (a refused connection, an exception of `settings.php`);
3. `drush status --field=bootstrap` other than `Successful`: notice
   `Drupal not installed, skipping upgrade`, the start goes on;
4. `drush cr`, `drush updb --yes`, `drush cr`; a failed step stops the start
   with its name.

Locale updates are not part of it.

### Healthcheck and /tmp cleanup

`freeunit-drupal-healthcheck` is a healthcheck for the web role of a site:

```yaml
healthcheck:
  test: ["CMD", "freeunit-drupal-healthcheck"]
```

It sends `GET http://127.0.0.1:$PORT$PATH` with `Host: $HOST`,
`X-Forwarded-For: 127.0.0.1`, `X-Forwarded-Host`, `X-Forwarded-Proto` and the
matching `X-Forwarded-Port` (443 or 80), `curl --max-time $TIMEOUT`, without
following redirects: 2xx and 3xx are healthy (a site that is not installed yet
answers 302), anything else and a timeout exit 1. Without `HEALTHCHECK_HOST` it
exits 1 with the variable's name. It fails while the configuration round
runs (the application listener is not up yet), including a round held by the
database wait of `90-` in the web role.

The `HEALTHCHECK` of the image is the base's and does not change: it asks the
Unit control socket, which the temporary daemon of the round answers too, so
it reports healthy before the listener exists. A site uses
`freeunit-drupal-healthcheck` for its compose healthcheck and
`depends_on: condition: service_healthy`.

`freeunit-drupal-tmp-cleanup [days]` (default 1) deletes the files of `/tmp`
older than `days` and then the empty directories as old (`find -mtime +N`:
at least `(N+1) * 24` hours), staying on the `/tmp` filesystem and leaving
symlinks alone; a non-numeric argument exits 64. Under the hardening fragment
`/tmp` is a bind mount on disk that nothing else empties: add a crontab line,
for example `30 3 * * * freeunit-drupal-tmp-cleanup 1`.

### Hardening fragment

`/usr/local/share/freeunit-drupal/docker-compose.hardening.yml` defines a
service `hardened`: `user` `${FREEUNIT_DRUPAL_RUN_UID:-65532}:${FREEUNIT_DRUPAL_RUN_GID:-65532}`,
`read_only`, `no-new-privileges`, `cap_drop: [ALL]`, the sysctl
`net.ipv4.ip_unprivileged_port_start: 0`, a 16 MB tmpfs `/run` of that uid and
`${FREEUNIT_DRUPAL_TMP_DIR}` bind-mounted at `/tmp` (compose stops when it is
unset). A site keeps a copy next to its compose file and extends it:

```yaml
services:
  unit:
    extends:
      file: docker-compose.hardening.yml
      service: hardened
```

`sysctls` does not work with `network_mode: host`. A relative
`FREEUNIT_DRUPAL_TMP_DIR` is resolved against the directory of the fragment
copy; the directory must belong to the run uid.

### Hardening check

`/usr/local/share/freeunit-drupal/test/hardening-check.sh` runs a site image
as unit and cron under the fragment, without a database, in its own compose
project `freeunit-drupal-hardening-<pid>` (removed on exit), and prints TAP:
start and health, the Unit listener, a static file (`/core/misc/drupal.js`),
`GET` and a 1 MB `POST` answered by PHP, `/run/msmtprc` when the site sets
`FREEUNIT_DRUPAL_SMTP_HOST`, `sendmail_path` of cli and embed, a restart, the
first cron job, the uid of every process, no write or privilege error in the
logs, the refusal of a root start and of a `/tmp` the uid cannot write. Exit 0:
every test passed; 1: a test failed; 2: a precondition failed (`Bail out!`).

What it does not see: `sendmail_path` of embed is read from the ini files, so a
value set in the site's Unit template (`options.admin`) or through
`PHP_INI_SCAN_DIR` is missed; health is the image `HEALTHCHECK` (control
socket), not `freeunit-drupal-healthcheck`, because there is no database; and
`/tmp` is a volume of the check's project, so a `FREEUNIT_DRUPAL_TMP_DIR` of the
wrong owner on the site host is not detected (only a `/tmp` the uid cannot write
is, as a refusal).

```sh
hardening-check.sh [--compose-copy <file>] <image>
```

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `--compose-copy <file>` | not checked | the site's copy must equal the fragment of `<image>` byte for byte |
| `FREEUNIT_DRUPAL_HARDENING_ENV_FILE` | none | env file of the site for both roles, after the defaults `FREEUNIT_DRUPAL_UNIT_CONFIG=1` and `FREEUNIT_DRUPAL_HEALTHCHECK_HOST` |
| `FREEUNIT_DRUPAL_HARDENING_HOST` | `localhost` | `Host` of the requests |
| `FREEUNIT_DRUPAL_HARDENING_WRITABLE_DIRS` | none | container dirs mounted as tmpfs of the run uid |
| `FREEUNIT_DRUPAL_HARDENING_CRONTAB` | none | crontab of the cron role; set, the check waits up to 75 s for the first job to finish |

The script runs on the host with the rights of the docker socket. Take it from
the image you verified, by digest, not from a branch:

```sh
digest=sha256:...   # the digest your site pins
gh attestation verify "oci://ghcr.io/6run0/freeunit-drupal@$digest" --owner 6RUN0
docker run --rm --entrypoint cat "ghcr.io/6run0/freeunit-drupal@$digest" \
  /usr/local/share/freeunit-drupal/test/hardening-check.sh > hardening-check.sh
sh hardening-check.sh --compose-copy docker-compose.hardening.yml <site image>
```

### Accepted risks

- The control socket, the generated dir and `/run/msmtprc` belong to the uid of
  the PHP workers: code execution in PHP can reconfigure Unit and the mail
  relay until the container restarts. The unix socket closes SSRF, not RCE.
  The wrapper therefore trusts `/run/msmtprc` because it exists: its writer
  is that same uid.
- Values rendered into the Unit configuration are readable through the control
  socket by that uid.
- `logfile -` puts recipient addresses into the container log.

## Environment variables

Variables inherited from the base image (`UNIT_ENTRYPOINT_QUIET_LOGS`) are
documented in the
[freeunit-php README](https://github.com/6RUN0/docker-freeunit-php#environment-variables).
The `FREEUNIT_DRUPAL_*` variables of the Drupal entrypoint scripts are listed
in [Variables](#variables). The default crontab reads one more:

| Variable | Default | Purpose |
|----------|---------|---------|
| `DRUPAL_CRON_URL` | _unset_ | URL of the Drupal cron endpoint (including the cron key) used by the default crontab. Falls back to `http://localhost:8080/cron.php` when unset. |

## Run as non-root

Both roles run as the image user `nonroot` (65532:65532) from the first
instruction: tini, the entrypoint, the FreeUnit master and PHP workers, and
supercronic with its jobs. No capability is needed; run with:

```bash
sudo install -d -o 65532 -g 65532 -m 0700 tmp   # once: the /tmp bind mount must belong to the uid
docker run --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /run:size=16m,uid=65532,gid=65532,mode=0700 \
  -v "$PWD/tmp:/tmp" \
  ...
```

| Path | Must be writable | Holds |
|------|------------------|-------|
| `/run` | yes (small tmpfs) | Unit control socket, pid, state (`/run/freeunit`), generated config |
| `/tmp` | yes (bind mount on disk) | request bodies up to `max_body_size`, PHP uploads and temp files, sessions, job temp files |
| `HOME` (`/home/nonroot`) | no | `composer install` and Drush run with a read-only `HOME` (see below) |
| your bind mounts | as the app needs | must be writable for the process uid (no `chown` at start) |

- With a read-only `HOME`, Composer has no global config (`composer config -g`
  fails) and no cache, git cannot write `~/.gitconfig` (`git config --global`,
  e.g. `safe.directory`), and ssh cannot record `known_hosts`. Point
  `COMPOSER_HOME` / `COMPOSER_CACHE_DIR` at a writable path when needed; give
  git its settings through `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` /
  `GIT_CONFIG_VALUE_<n>` or an `/etc/gitconfig` baked into a derived image.
- Any non-root uid:gid works (`--user` / compose `user:`); give the tmpfs the
  same `uid=`/`gid=`. ssh (git over SSH) needs a passwd entry for the uid:
  65532 has one, another uid needs its own in a derived image.
- A listener below 1024 needs `net.ipv4.ip_unprivileged_port_start=0`
  (the Docker default; set it explicitly with `--sysctl`).
- A root start (`--user 0:0`) is dropped to 65532 when the container has
  `CAP_SETUID`, `CAP_SETGID`, `CAP_CHOWN` and `CAP_KILL` (tini stays root and
  forwards `docker stop` to the 65532 processes), and refused otherwise. A
  fallback, not a recommended mode.
- The control API, the state dir and the generated dir belong to the same uid
  as the PHP workers (see [Accepted risks](#accepted-risks)).
- `docker exec` runs as the container user; `docker exec -u 0` bypasses all of
  the above. Use it read-only.

See the [freeunit-php README](https://github.com/6RUN0/docker-freeunit-php#run-as-non-root)
for the details.

Treat `/docker-entrypoint.d/*.sh` as trusted input only: those scripts run in
the entrypoint shell before FreeUnit starts.

## Stability

From 0.5.0 the items below are the public contract of the image. Changing any
of them is a breaking change: a `Changed` entry in the changelog and a new
minor version (0.x).

1. The variables of [Variables](#variables), their accepted values and
   defaults, including the flag values (unset, empty, `0`, `1`), the
   interpolation `FREEUNIT_DRUPAL_RUN_UID`, `_RUN_GID`, `_TMP_DIR` of the
   fragment and the `FREEUNIT_DRUPAL_HARDENING_*` parameters. The prefixes
   `FREEUNIT_DRUPAL_`, `freeunit_drupal_` and `_fd_` are reserved.
2. The script names `/docker-entrypoint.d/10-freeunit-drupal-writable-dirs.sh`,
   `20-freeunit-drupal-msmtp.sh`, `30-freeunit-drupal-unit-config.sh`,
   `90-freeunit-drupal-upgrade.sh`; the slot rule of
   [Order and site scripts](#order-and-site-scripts); and the invariant that an
   image script without its variable writes and changes nothing, so a new
   `NN-freeunit-drupal-*` script in a later release does not move a site's
   scripts.
3. The paths `/usr/local/bin/freeunit-drupal-sendmail`,
   `/usr/local/bin/freeunit-drupal-healthcheck`,
   `/usr/local/bin/freeunit-drupal-tmp-cleanup`; the ini
   `05-freeunit-drupal-sendmail.ini` in `cli` and `embed`; `/usr/sbin/sendmail`
   as the wrapper; `/run/msmtprc` and its first line `# freeunit-drupal`;
   `$ENTRYPOINT_GENERATED_DIR/freeunit-drupal.json`;
   `/usr/local/share/freeunit-drupal/unit.json.template` and the defaults and
   routes of the built-in template;
   `/usr/local/share/freeunit-drupal/docker-compose.hardening.yml` with its
   service `hardened`; `/usr/local/share/freeunit-drupal/test/hardening-check.sh`
   and its arguments.
4. `/usr/local/lib/freeunit-drupal/lib.sh` and only these functions:
   `freeunit_drupal_log_info`, `freeunit_drupal_log_notice`,
   `freeunit_drupal_log_warn`, `freeunit_drupal_die`,
   `freeunit_drupal_flag_enabled`, `freeunit_drupal_drush`,
   `freeunit_drupal_wait_for_db`.

Not part of the contract: the base library functions and variables `lib.sh`
uses internally, the `_fd_*` names, the text of log messages, and the content
of `examples/drupal` (a site copies it and owns the copy).

## See also

- [Changelog](CHANGELOG.md)
- [freeunit-php base image](https://github.com/6RUN0/docker-freeunit-php)
- [FreeUnit (upstream)](https://github.com/freeunitorg/freeunit)
- [supercronic](https://github.com/aptible/supercronic)
- [Unit in Docker at unit.nginx.org](https://unit.nginx.org/howto/docker/)
