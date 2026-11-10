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
docker build -t freeunit-drupal .                       # defaults: base 0.4.0 by tag only, php8.4
docker build --build-arg PHP_VER=8.3 -t x .            # one-off without make
make BASE_TAG=trixie BASE_DIGEST= php8.4               # track the floating substrate
# test on an unreleased local base image <local-base>:trixie-php8.3
make IMAGE=x BASE_IMAGE=<local-base> BASE_TAG=trixie BASE_DIGEST= DEFAULT_PHP=8.3 test
```

Key build args (defaults in the `Dockerfile`):

- `BASE_IMAGE` — base registry path (`ghcr.io/6run0/freeunit-php`)
- `BASE_TAG` - the freeunit-php release the base is pinned to (`0.4.0`; the
  FROM tag is `${BASE_TAG}-php${PHP_VER}`)
- `BASE_DIGEST_PHP83` / `BASE_DIGEST_PHP84` / `BASE_DIGEST_PHP85` - the digest
  of `${BASE_TAG}-php<X.Y>` per PHP line; `BASE_DIGEST` - the one the FROM
  line uses (`@${BASE_DIGEST}` is appended only when it is non-empty)
- `PHP_VER` — PHP version (`8.4`)
- `SUPERCRONIC_VERSION` / `SUPERCRONIC_SHA256` — supercronic release pin
- `COMPOSER_VERSION` — Composer release pin (empty = track `latest/download/`)
- `COMPOSER_GPG_FINGERPRINT` — fingerprint of the Composer signing key

The `Makefile` reads `BASE_IMAGE`, `BASE_TAG`, `PHP_VER` and the
`BASE_DIGEST_PHP<XY>` table from the `Dockerfile` ARGs via `sed`, so they are
**single-sourced**: bumping supercronic = edit both `SUPERCRONIC_VERSION` and
`SUPERCRONIC_SHA256` in the `Dockerfile` only. Each `php<X.Y>` target passes
its table entry as `BASE_DIGEST`; an empty entry is a `make` error, unless
`BASE_DIGEST` is given on the command line (empty = tag only). Overriding
`BASE_IMAGE` or `BASE_TAG` without `BASE_DIGEST` is a `make` error too: the
table digest would win over the tag (`tag@digest` resolves by digest).

The PHP matrix is single-sourced the same way: the workflows read it from the
`Makefile` via `make print-php-matrix` / `make print-default-php` (a
`php-matrix` job feeding `fromJSON()` matrices), so adding or removing a PHP
line is one `PHP_VERSIONS` edit in the `Makefile`.

`make` tags its builds `$(IMAGE):local-php<X.Y>`, a local tag that is never
published; `release.yml` publishes `<version>-php<X.Y>`, and on the default
PHP line `<version>` and `latest`.

## Dockerfile architecture

Single-stage FROM, no multi-stage build:

```dockerfile
FROM ${BASE_IMAGE}:${BASE_TAG}-php${PHP_VER}${BASE_DIGEST:+@}${BASE_DIGEST}
USER 0:0
...
USER 65532:65532
```

The base runs as `nonroot` (65532:65532); `USER 0:0` covers the `RUN`, the last
instruction switches back. Numeric on purpose: hadolint 2.15.1 rejects a
non-numeric `USER` (DL3066).

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
  `supercronic` launch mode. Sourced by the base entrypoint as the container
  user before dispatch. Defines `handle_supercronic` only - no top-level side
  effects. Portable POSIX sh (`#!/bin/sh`, checked with `shellcheck -s sh`,
  `dash -n`, `busybox sh -n`): no bashisms, no `local`, so its variables carry
  the `supercronic_` prefix.
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
`/docker-entrypoint-hook.d/` as the container user before dispatch (a root
start is dropped to 65532 or refused first). A hook file must be owned by root
and not group/world-writable (`assert_safe_root_file`). When the container
command is `supercronic`, `dispatch_handler` calls `handle_supercronic`.

`handle_supercronic` in `rootfs/docker-entrypoint-hook.d/supercronic.sh`:

1. `shift`s off the `supercronic` command token, leaving the operator's own
   arguments (flags and/or a crontab path) in `"$@"`.
2. Calls `run_entrypoint_scripts` (public base-library function — runs `*.sh`
   drop-ins from `/docker-entrypoint.d/`, no daemon required).
3. Trailing argument an existing file: the operator's crontab. No argument or
   a trailing flag: appends the default `/etc/supercronic/crontab` (validated
   readable). Anything else: `die "supercronic crontab not found: ..."`.
   Prepends `-no-reap` unless the operator passed it (tini is PID 1 and reaps).
4. `exec supercronic "$@"` - no privilege drop and no capability: the jobs run
   as the container user. The base has no `exec_as_user`/`setup_user`; a hook
   calling them fails at start.

Hook authoring rules (enforced by the base dispatcher):

- Only define `handle_*` functions — no top-level side effects.
- `handle_<cmd>` must `exec` the final process.
- Do not shadow base library names (`log*`, `die`, `run_entrypoint_scripts`,
  `dispatch_handler`, `has_handler`, ...) or the entrypoint's variable
  prefixes `UNIT_*`, `ENTRYPOINT_*`, `_ep_*`; a hook's variables and
  helper functions carry the `<cmd>_` prefix.
- Portable POSIX sh, sourced with `.` into the image's `/bin/sh` (dash); a
  bash construct is a parse error at start. No bare `trap`, no `set` changes.
- `dispatch_handler` picks `handle_$1` only when `command -v` reports a shell
  function, and calls it left of `||`: `set -e` is off inside the handler.

## Verification

- **Build** — the `RUN` layer ends with `--version` invocations for every
  installed tool, so a successful build proves each one loaded.
- **Smoke test** — `test/smoke.sh <image-ref>` (plus `--build` and `--php X.Y`
  flags, parsed by `test/lib.sh`) runs the image in both roles and asserts:
  the web role serves PHP through FreeUnit, every toolchain binary actually runs
  (incl. the `sendmail -> msmtp` symlink), and the cron role executes jobs as
  the app user (not root). Both roles run `--user 65532:65532 --read-only
  --cap-drop=ALL --security-opt=no-new-privileges` with tmpfs `/run` and `/tmp`
  only; every process must run as 65532 and the logs must carry no
  `Read-only file system` / `Operation not permitted` / `Permission denied`.
  It also checks the hook is `root:root` and not group/world-writable,
  `-no-reap`, the refusal of a missing crontab path, and the cron role as uid
  12345 (no passwd entry, marker `cron-ok-12345`).
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
  Actions; its PRs target `develop`.
- `.github/workflows/release.yml` - tag-driven (`v*`): builds + smoke-tests the
  PHP matrix, refuses to run when an immutable tag (`:$VERSION-php*`, bare
  `:$VERSION`) already exists, pushes `:$VERSION-php*`, records keyless (OIDC)
  provenance + SPDX SBOM attestations bound to the image **digest**; the
  `default-tags` job (after every leg) copies the digest of
  `:$VERSION-php<default>` to `:$VERSION` and `:latest`
  (`imagetools create --prefer-index=false`), then the `release` job cuts a
  GitHub Release with notes extracted from `CHANGELOG.md`. There is no per-PHP
  floating tag.
- `.github/workflows/security-scan.yml` — weekly (Tue 06:41 UTC) trivy re-scan
  of the *published* GHCR images (`<latest release>-php<X.Y>`) across the PHP
  matrix, skipping with a notice a PHP line the last release lacks;
  report-only, SARIF uploaded to code scanning.
- `.github/workflows/check-upstream.yml` — weekly (Mon 06:17 UTC) upstream
  watcher: one parameterized `bump` matrix job for the pinned ARGs plus a
  separate `base-image` job. **supercronic**: downloads the amd64 binary,
  recomputes `SUPERCRONIC_SHA256`, and opens a `chore/supercronic-*` PR (into
  `develop`, like every bump PR) bumping
  both ARGs. **composer**: opens a `chore/composer-*` PR bumping `COMPOSER_VERSION`
  (no checksum - the phar is GPG-verified at build). **base-image**: on a new
  upstream release it opens a heads-up *issue* (not a PR), deduped across any
  issue state, carrying the new `BASE_TAG` and the `BASE_DIGEST_PHP<XY>` lines
  read from the registry; bump them in the `Dockerfile` manually in response. Each watcher only opens
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
- The base is pinned by `BASE_TAG` (a freeunit-php release) **and** by digest
  per PHP line (`BASE_DIGEST_PHP<XY>`): the tag alone is mutable. A plain
  `docker build` has an empty `BASE_DIGEST` and pulls by tag only; `make`,
  CI and `release.yml` always pass the table entry. `make BASE_TAG=trixie
  BASE_DIGEST= php8.4` tracks the floating suite tag locally.
- The image runs as `nonroot` (65532:65532): `/run` and `/tmp` must be writable
  at run time (tmpfs / bind mount), HOME may stay read-only. Unit configs carry
  no `applications.*.user/group`.
- Composer is **pinned** by default via the `COMPOSER_VERSION` ARG (bumped by the
  `check-upstream` workflow), and the GPG signature still verifies integrity on
  every build. Pass `--build-arg COMPOSER_VERSION=` (empty) to track
  `latest/download/` instead, or another release to pin a different version.
- `msmtp` requires configuration (SMTP server, credentials) at runtime —
  the image provides the binary, the `/usr/sbin/sendmail` symlink, and a
  fully-commented template at `/etc/msmtprc` to start from.
- `.dockerignore` is an allowlist (`*` then `!rootfs/`) — only `rootfs/`
  enters the build context.
- `.github/zizmor.yml` disables zizmor's `self-repository` audit: it demands
  `uses: $/.github/actions/...`, which actionlint (1.7.12, rhysd/actionlint
  #711) rejects as an invalid action ref. Keep `./` local-action refs until
  actionlint accepts `$/`, then switch and drop the override.
