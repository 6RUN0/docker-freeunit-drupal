# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Tooling

`.mcp.json` stays tracked — keep it in git, do not gitignore it. It wires two
local MCP servers — use them:

- **codegraph** — a queryable knowledge graph of the codebase. Consult it
  before editing code (e.g. `codegraph_explore` for "how does X work",
  callers/callees, change impact) instead of grepping and re-reading files by
  hand.
- **agentmemory** (served via `local_1mcp` with the `agentmemory` tag) — the
  persistent project memory. Recall prior lessons/decisions before starting
  non-trivial work, and save durable findings (review outcomes, gotchas,
  release-bump steps) so they survive across sessions.

## What this repo is

A single parameterized `Dockerfile` that builds Docker images extending
[`ghcr.io/6run0/freeunit-php`](https://github.com/6RUN0/docker-freeunit-php)
(FreeUnit — a fork of NGINX Unit — with an embedded PHP module on Debian
trixie, amd64) with the toolchain a Drupal site needs at runtime:

- Composer (`.phar`, GPG-verified against the pinned maintainer key)
- supercronic (pinned by version + SHA256-verified)
- APT packages: `git` + `openssh-client` (deploy config/code over SSH git),
  `mariadb-client` + `less` (DB inspection through a pager), `msmtp` (SMTP
  `sendmail` drop-in, symlinked as `/usr/sbin/sendmail`), `patch`
  (cweagans/composer-patches applies drupal.org patches with it), `unzip`
  (Composer archive extraction)

The Drupal application code is **not** baked into the image. This image is the
runtime environment, not the site.

`examples/drupal/` carries a self-contained `docker compose` stack (web +
cron + MariaDB) showing the image running in both roles.

## Build matrix

The `Makefile` drives the matrix; each target is one `docker build` with
different `--build-arg`s against the same `Dockerfile`:

```bash
make            # all PHP versions (PHP_VERSIONS = 8.3 8.4 8.5)
make php8.4     # one variant
make latest     # build DEFAULT_PHP (8.4) and tag it :latest
make test       # build the default PHP and run the smoke test
docker build -t freeunit-drupal .                       # defaults: trixie, php8.4
docker build --build-arg PHP_VER=8.3 -t x .            # one-off without make
make BASE_TAG=trixie php8.4                            # track the floating substrate
```

Key build args (defaults in the `Dockerfile`):

- `BASE_IMAGE` — base registry path (`ghcr.io/6run0/freeunit-php`)
- `BASE_TAG` — base image tag fragment; pinned to a released build like
  `trixie-1.35.6-build3` for reproducibility (override with `trixie` to float)
- `PHP_VER` — PHP version (`8.4`)
- `SUPERCRONIC_VERSION` / `SUPERCRONIC_SHA256` — supercronic release pin
- `COMPOSER_VERSION` — Composer release pin (empty = track `latest/download/`)
- `COMPOSER_GPG_FINGERPRINT` — fingerprint of the Composer signing key

The `Makefile` reads `BASE_IMAGE`, `BASE_TAG`, and `PHP_VER` from the
`Dockerfile` ARGs via `sed`, so they are **single-sourced**: bumping
supercronic = edit both `SUPERCRONIC_VERSION` and `SUPERCRONIC_SHA256` in the
`Dockerfile` only.

The PHP matrix is single-sourced the same way: the workflows read it from the
`Makefile` via `make print-php-matrix` / `make print-default-php` (a
`php-matrix` job feeding `fromJSON()` matrices), so adding or removing a PHP
line is one `PHP_VERSIONS` edit in the `Makefile`.

The image tag mirrors the substrate: `$(BASE_TAG)-php$*` (e.g.
`trixie-1.35.6-build3-php8.4`).

## Dockerfile architecture

Single-stage FROM, no multi-stage build:

```dockerfile
FROM ghcr.io/6run0/freeunit-php:${BASE_TAG}-php${PHP_VER}
```

One `RUN` layer installs everything:

1. Mark the base's manually-installed packages with `apt-mark showmanual` so
   build-only deps (gnupg/dirmngr, needed for Composer GPG verification) can
   be auto-removed afterwards without removing base packages.
2. Install `dirmngr gnupg`; mark all as auto; restore the base's manual marks.
3. Download and GPG-verify Composer `.phar` against the pinned key fingerprint
   (via `hkps://keys.openpgp.org`).
4. Download and SHA256-verify supercronic binary (string comparison, not a
   pipe, to satisfy hadolint DL4006).
5. Install runtime APT packages.
6. Auto-remove gnupg/dirmngr.
7. Symlink msmtp as sendmail.
8. Prove each tool loaded (`--version` / `-V` calls).

`COPY rootfs/ /` adds the hook, the default crontab, and the msmtp template.

## rootfs overlay

`rootfs/` mirrors the container filesystem:

- `rootfs/docker-entrypoint-hook.d/supercronic.sh` — the hook that adds the
  `supercronic` launch mode. Sourced by the base entrypoint as root before
  dispatch. Defines `handle_supercronic` only — no top-level side effects.
- `rootfs/etc/supercronic/crontab` — a commented template with **no active
  jobs**: a schedule-syntax reference (incl. supercronic's extended syntax —
  sub-minute seconds field, year field, `@`-macros, `L`/`W`/`#`) plus two
  commented example jobs: project-local Drush (the preferred way to run Drupal
  cron) and the HTTP trigger. The cron role idles until a job is
  enabled — uncomment one, or mount a custom crontab at the same path (set
  `DRUPAL_CRON_URL` to the full Drupal cron URL, including the cron key, for the
  HTTP example).
- `rootfs/etc/msmtprc` — a commented msmtp configuration template with **no
  active settings**: shared defaults (TLS, stdout logging) plus an SMTP account
  example using `passwordeval` to read the secret from a mounted file. Mail
  stays unconfigured until the operator uncomments and edits it, mounts a real
  config at the same path, or bakes one into a derived image.

## Cron hook contract

The base entrypoint (`ghcr.io/6run0/freeunit-php`) sources every `*.sh` in
`/docker-entrypoint-hook.d/` as root before dispatch. When the container
command is `supercronic`, `dispatch_handler` calls `handle_supercronic`.

`handle_supercronic` in `rootfs/docker-entrypoint-hook.d/supercronic.sh`:

1. `shift`s off the `supercronic` command token, leaving the operator's own
   arguments (flags and/or a crontab path) in `"$@"`.
2. Calls `run_entrypoint_scripts` (public base-library function — runs `*.sh`
   drop-ins from `/docker-entrypoint.d/`, no daemon required).
3. Appends the default `/etc/supercronic/crontab` (validated readable) only when
   the operator's trailing argument is not itself an existing file, so flags pass
   through while a bare invocation still runs the baked-in crontab.
4. Calls `exec_as_user "$APPLICATION_USER" "$APPLICATION_GROUP" supercronic
   "$@"` — uses `setpriv` (requires `CAP_SETUID` + `CAP_SETGID`; gosu is
   intentionally absent).

Hook authoring rules (enforced by the base dispatcher):

- Only define `handle_*` functions — no top-level side effects.
- `handle_<cmd>` must `exec` the final process.
- Do not shadow base library names or `APPLICATION_*` / `UNIT_ENTRYPOINT_*`
  variables.

## Verification

- **Build** — the `RUN` layer ends with `--version` invocations for every
  installed tool, so a successful build proves each one loaded.
- **Smoke test** — `test/smoke.sh <image-ref>` (plus `--build` and `--php X.Y`
  flags, parsed by `test/lib.sh`) runs the image in both roles and asserts:
  the web role serves PHP through FreeUnit, every toolchain binary actually runs
  (incl. the `sendmail -> msmtp` symlink), and the cron role executes jobs as
  the app user (not root).
- **CI** — `.github/workflows/ci.yml` runs lint (hadolint, shellcheck, typos,
  actionlint, zizmor, rumdl) and the build + smoke test matrix (read from the
  `Makefile`'s `PHP_VERSIONS`) with a per-PHP Buildx layer cache; trivy scan
  on the default-PHP leg (report-only).

Run locally:

```bash
make lint   # hadolint, shellcheck, rumdl, typos (each skipped if not installed)
make test   # build default PHP and run smoke test
make scan   # trivy/grype CVE scan (skipped if neither is installed)
```

## Automation

- `.github/workflows/ci.yml` — triggered on push/PR to `main` or `develop`;
  runs lint + build+test matrix + trivy scan. Dependabot manages SHA-pinned
  Actions.
- `.github/workflows/release.yml` — tag-driven (`v*`): builds + smoke-tests the
  PHP matrix, pushes the floating, `:$VERSION-php*`, `:latest`, and bare
  `:$VERSION` tags to GHCR, records keyless (OIDC) provenance + SPDX SBOM
  attestations bound to the image **digest**, then cuts a GitHub Release with
  notes extracted from `CHANGELOG.md`.
- `.github/workflows/security-scan.yml` — weekly (Tue 06:41 UTC) trivy re-scan
  of the *published* GHCR images across the PHP matrix; report-only, SARIF
  uploaded to code scanning.
- `.github/workflows/check-upstream.yml` — weekly (Mon 06:17 UTC) upstream
  watcher: one parameterized `bump` matrix job for the pinned ARGs plus a
  separate `base-image` job. **supercronic**: downloads the amd64 binary,
  recomputes `SUPERCRONIC_SHA256`, and opens a `chore/supercronic-*` PR bumping
  both ARGs. **composer**: opens a `chore/composer-*` PR bumping `COMPOSER_VERSION`
  (no checksum — the phar is GPG-verified at build). **base-image**: `BASE_TAG` is
  pinned to a released build, but the watcher still opens a heads-up *issue*
  (not yet a PR) on a new upstream release, deduped across any issue state; bump
  `BASE_TAG` in the `Dockerfile` manually in response. Each watcher only opens
  the PR/issue (never merges). Because PRs are
  created with the built-in `GITHUB_TOKEN`, CI does **not** run on them
  automatically — close/reopen the PR or push an empty commit to trigger the
  build + smoke matrix that actually downloads and checksum-verifies the binary. A
  manual supercronic bump is still possible by editing `SUPERCRONIC_VERSION` +
  `SUPERCRONIC_SHA256` in the `Dockerfile` (verify the SHA256 from the
  [supercronic releases page](https://github.com/aptible/supercronic/releases)).

## Gotchas

- The image is **amd64 only** (the base image `freeunit-php` ships amd64
  only).
- `BASE_TAG` is **pinned** by default to a released `freeunit-php` build (e.g.
  `trixie-1.35.6-build3`) for reproducible releases. Pass `--build-arg
  BASE_TAG=trixie` (or `make BASE_TAG=trixie …`) to track the floating suite
  tag — the newest release carrying that suite — locally. Note the pin is still
  a *tag* (mutable in principle), not a `@sha256:` digest: the `FROM` join
  `${BASE_TAG}-php${PHP_VER}` can't carry a per-image digest without giving up
  the single-Dockerfile matrix, so a pinned build tag is the reproducibility
  lever here. The published `${BASE_TAG}-php${PHP_VER}` image tag mirrors the
  pinned substrate, so it changes when `BASE_TAG` is bumped.
- Composer is **pinned** by default via the `COMPOSER_VERSION` ARG (bumped by the
  `check-upstream` workflow), and the GPG signature still verifies integrity on
  every build. Pass `--build-arg COMPOSER_VERSION=` (empty) to track
  `latest/download/` instead, or another release to pin a different version.
- `msmtp` requires configuration (SMTP server, credentials) at runtime —
  the image provides the binary, the `/usr/sbin/sendmail` symlink, and a
  fully-commented template at `/etc/msmtprc` to start from.
- `.dockerignore` is an allowlist (`*` then `!rootfs/`) — only `rootfs/`
  enters the build context.
