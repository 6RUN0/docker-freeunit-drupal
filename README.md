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
  out of the box), and `unzip` (Composer archive extraction).

The Drupal application code is **not** baked into the image. It is mounted
or installed by Composer at runtime. This image is the runtime environment,
not the site.

- **Base image:** `ghcr.io/6run0/freeunit-php` (trixie, amd64)
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
| `<version>` | `:0.1.0` | that repo release, default PHP |
| `<base-tag>-php<X.Y>` | `:trixie-php8.4` | newest release on a PHP line (floats forward) |
| `<version>-php<X.Y>` | `:0.1.0-php8.4` | a specific release on a PHP line |

```bash
docker pull ghcr.io/6run0/freeunit-drupal:trixie-php8.4
```

The `latest` and `<base-tag>-php<X.Y>` tags float to the latest release.
The `<version>…` tags are pinned to a single release. The substrate
(`freeunit-php`) is pinned via `BASE_TAG` — see the Build section.

## Build

```bash
# Default image (trixie, php8.4)
docker build -t freeunit-drupal .

# A specific PHP version
docker build --build-arg PHP_VER=8.3 -t freeunit-drupal:8.3 .

# Pin the freeunit-php substrate to a released build
docker build --build-arg BASE_TAG=trixie-1.35.5-build4 -t freeunit-drupal .
```

Or use the Makefile:

```bash
make                                        # build all PHP versions (8.3, 8.4, 8.5)
make php8.3                                 # build one variant
make latest                                 # build the default PHP (8.4) and tag :latest
make test                                   # build the default PHP and run the smoke test
make lint                                   # run all installed linters
make scan                                   # CVE-scan the default image (trivy/grype if installed)
make BASE_TAG=trixie-1.35.5-build4 php8.4  # pin the substrate
```

The per-release defaults (`BASE_IMAGE`, `BASE_TAG`, `PHP_VER`) live in the
`Dockerfile` ARGs. The `Makefile` reads them from there, so a substrate bump
is a single edit in the `Dockerfile`. The only asset pinned in this repo is
`supercronic` (version + SHA256 in the `Dockerfile` ARGs).

## Run

### Web role

The primary use: run a Drupal site under the FreeUnit web server.

```bash
docker run -d --name drupal \
  -p 8080:8080 \
  -v "$PWD/web:/www:ro" \
  -v "$PWD/config.json:/docker-entrypoint.d/config.json:ro" \
  ghcr.io/6run0/freeunit-drupal:trixie-php8.4
```

On first start the base entrypoint applies everything in
`/docker-entrypoint.d/` (scripts, certificates, Unit config) and then starts
the Unit daemon in the foreground. See the base image documentation for the
full first-run behaviour and the `/docker-entrypoint.d/` conventions.

A minimal Unit `config.json` for Drupal:

```json
{
  "listeners": { "*:8080": { "pass": "applications/drupal" } },
  "applications": {
    "drupal": {
      "type": "php",
      "root": "/www",
      "script": "index.php",
      "user": "unit",
      "group": "unit"
    }
  }
}
```

### Cron role

Run the same image as a supercronic cron runner alongside the web container,
without a separate image and without overriding the entrypoint.

```bash
docker run -d --name drupal-cron \
  -v "$PWD/crontab:/etc/supercronic/crontab:ro" \
  -e DRUPAL_CRON_URL=http://localhost:8080/cron.php?cron_key=YOUR_KEY \
  ghcr.io/6run0/freeunit-drupal:trixie-php8.4 supercronic
```

The shipped crontab is a commented template with no active jobs, so mount your
own (as above) or enable a job in a derived image — see [Default crontab](#default-crontab).

Passing `supercronic` as the container command activates the cron role. The
base entrypoint's `dispatch_handler` recognises it and calls
`handle_supercronic` from the hook at
`/docker-entrypoint-hook.d/supercronic.sh`, which:

1. Runs any operator `*.sh` drop-ins from `/docker-entrypoint.d/` (the same
   convenience the web role provides).
2. Drops from root to the app user (`APPLICATION_USER` / `APPLICATION_GROUP`,
   default `unit:unit`) via `setpriv`.
3. `exec`s `supercronic`, forwarding any arguments you appended after the
   `supercronic` command and adding the default crontab path when you didn't
   pass one (see [Tuning supercronic](#tuning-supercronic)).

#### Default crontab

The image ships `/etc/supercronic/crontab` as a **commented template with no
active jobs** — it documents the schedule syntax and carries the Drupal
HTTP-trigger job as a commented example:

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
`http://localhost:8080/cron.php?cron_key=YOUR_KEY`). Alternatively, mount
a custom crontab that calls `vendor/bin/drush cron` from your Composer
project instead of the HTTP endpoint.

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
  ghcr.io/6run0/freeunit-drupal:trixie-php8.4 supercronic -inotify -debug
```

When your trailing argument names a readable file it is used as the crontab;
otherwise the image default (`/etc/supercronic/crontab`) is appended, so adding
a flag still runs the baked-in crontab. Run `supercronic -help` for the full
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
- A `handle_<cmd>` **must `exec`** the final process. Returning or exiting
  non-zero is a fatal contract violation.
- Do not shadow base library function names or `APPLICATION_*` /
  `UNIT_ENTRYPOINT_*` variables.

### `/docker-entrypoint.d/` conventions

This image inherits the base entrypoint's `/docker-entrypoint.d/` processing
unchanged. Files are applied in lexical order, by extension:

| Extension | Action |
|-----------|--------|
| `*.sh`    | Executed as root. |
| `*.pem`   | Uploaded as a certificate bundle named after the file (minus `.pem`). |
| `*.json`  | `PUT` to the Unit `config` via the control socket. |

Other file types are logged and ignored.

> Multiple `*.json` are **not** merged: `PUT /config` replaces the whole
> configuration, so only the lexically-last file takes effect (the entrypoint
> warns when more than one is present). Ship a single combined config file.

In the cron role the `*.sh` drop-ins run, but `*.pem` and `*.json` are not
processed (Unit is not started in that role).

## Environment variables

Variables inherited from the base image (`APPLICATION_*` and
`UNIT_ENTRYPOINT_QUIET_LOGS`) are documented in the
[freeunit-php README](https://github.com/6RUN0/docker-freeunit-php#environment-variables).
This image adds one variable of its own:

| Variable | Default | Purpose |
|----------|---------|---------|
| `DRUPAL_CRON_URL` | _unset_ | URL of the Drupal cron endpoint (including the cron key) used by the default crontab. Falls back to `http://localhost:8080/cron.php` when unset. |

## Security posture

The Unit master process and the cron role both require `CAP_SETUID` and
`CAP_SETGID` — the Unit master to spawn per-app workers, and the cron hook to
drop root via `setpriv`. Run with:

```bash
docker run --cap-drop=ALL \
  --cap-add=SETUID \
  --cap-add=SETGID \
  --security-opt=no-new-privileges \
  ...
```

Drop privileges for the Drupal application itself with the `user`/`group`
keys in the Unit config (web role) or via `APPLICATION_USER` / `APPLICATION_GROUP`
(cron role — `handle_supercronic` passes these to `exec_as_user`).

Treat `/docker-entrypoint.d/*.sh` as trusted input only — those scripts run
as root inside the container.

## See also

- [Changelog](CHANGELOG.md)
- [freeunit-php base image](https://github.com/6RUN0/docker-freeunit-php)
- [FreeUnit (upstream)](https://github.com/freeunitorg/freeunit)
- [supercronic](https://github.com/aptible/supercronic)
- [Unit in Docker at unit.nginx.org](https://unit.nginx.org/howto/docker/)
