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
  (inspect the database, e.g. `SELECT … \G` through a pager), `msmtp` (an SMTP
  `sendmail` drop-in, symlinked as `/usr/sbin/sendmail` so PHP's `mail()` works
  out of the box), `patch` (so `cweagans/composer-patches` can apply drupal.org
  patches during `composer install`), and `unzip` (Composer archive extraction).

The Drupal application code is **not** baked into the image. It is mounted
or installed by Composer at runtime. This image is the runtime environment,
not the site.

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
the FreeUnit daemon in the foreground. See the base image documentation for the
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

PHP's `mail()` invokes `/usr/sbin/sendmail`, which this image symlinks to
`msmtp`. The shipped `/etc/msmtprc` is a **commented template with no active
settings** — mail stays unconfigured until you point it at your SMTP relay:
uncomment and edit the template in a derived image, or mount your own config
at the same path:

```bash
-v "$PWD/msmtprc:/etc/msmtprc:ro"
```

`/etc` is not writable for the container user. A configuration rendered at
start-up goes to a writable path and is named explicitly, e.g. with
`sendmail_path = "/usr/bin/msmtp -C /run/msmtprc -t -i"` in a PHP ini for both
`cli` and `embed` (cron jobs send mail through PHP CLI), or to `~/.msmtprc`
when `HOME` is writable.

Keep credentials out of the world-readable config file: the template uses
`passwordeval` to read the password from a mounted secret (e.g.
`/run/secrets/smtp_password`) instead of a plaintext `password` line.

## Environment variables

Variables inherited from the base image (`UNIT_ENTRYPOINT_QUIET_LOGS`) are
documented in the
[freeunit-php README](https://github.com/6RUN0/docker-freeunit-php#environment-variables).
This image adds one variable of its own:

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
  as the PHP workers: code execution in PHP can reconfigure Unit until the
  container restarts. The unix socket closes SSRF, not RCE.
- `docker exec` runs as the container user; `docker exec -u 0` bypasses all of
  the above. Use it read-only.

See the [freeunit-php README](https://github.com/6RUN0/docker-freeunit-php#run-as-non-root)
for the details.

Treat `/docker-entrypoint.d/*.sh` as trusted input only: those scripts run in
the entrypoint shell before FreeUnit starts.

## See also

- [Changelog](CHANGELOG.md)
- [freeunit-php base image](https://github.com/6RUN0/docker-freeunit-php)
- [FreeUnit (upstream)](https://github.com/freeunitorg/freeunit)
- [supercronic](https://github.com/aptible/supercronic)
- [Unit in Docker at unit.nginx.org](https://unit.nginx.org/howto/docker/)
