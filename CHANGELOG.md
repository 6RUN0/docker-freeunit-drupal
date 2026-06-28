# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions here track the **packaging** (this repo), not the bundled software; each
release records the base image and PHP versions it ships.

## [0.3.1] - 2026-06-28

Ships the Debian trixie `freeunit-php` base **pinned to `trixie-1.35.6-build3`**
(FreeUnit `1.35.6-1`, base release `v0.0.7`), PHP **8.3 / 8.4 / 8.5** (default
8.4), Composer **2.10.1** (pinned), supercronic **v0.2.46**.

### Changed

- Pin the `freeunit-php` substrate: `BASE_TAG` now defaults to the released build
  `trixie-1.35.6-build3` instead of the floating `trixie` suite tag, so a release
  builds on a known base and rebuilding a git tag is reproducible. The published
  base-named convenience tag follows the substrate
  (`:trixie-1.35.6-build3-php8.4`); the `:latest`, `:<version>`, and
  `:<version>-php<X.Y>` consumer tags are unchanged. Override with
  `--build-arg BASE_TAG=trixie` (or `make BASE_TAG=trixie …`) to track the
  floating substrate locally. The pinned base is a rebuild-only refresh of the
  prior `1.35.6-1` package (no FreeUnit or PHP version change).

## [0.3.0] - 2026-06-22

Ships the Debian trixie `freeunit-php` base (now rebranded -- daemon
`freeunitd`, app user `freeunit`, base `v0.0.6`+), PHP **8.3 / 8.4 / 8.5**
(default 8.4), Composer **2.10.1** (pinned), supercronic **v0.2.46**.

### Changed

- Align the bundled config and tests with the `freeunit-php` base image's
  `unit` -> `freeunit` rebrand (base `v0.0.6`): the daemon binary is now
  `freeunitd` and the default application user/group is `freeunit`. The example
  and fixture `config.json` run PHP workers as `freeunit:freeunit`, and the
  smoke test's app-user default tracks the new name (still overridable via
  `SMOKE_APP_USER`). The image path (`ghcr.io/6run0/freeunit-php`) is unchanged.
- Build and smoke-test verification widened: the Dockerfile's toolchain
  `--version` block and the smoke test now exercise `ssh` (openssh-client) and
  `less`, the two documented runtime deps they previously skipped. The smoke
  test also asserts the served PHP version matches the line under test and --
  the web-role mirror of the existing cron check -- that the PHP worker runs as
  the app user (`freeunit`), not root.

## [0.2.0] - 2026-06-10

Ships the Debian trixie `freeunit-php` base, PHP **8.3 / 8.4 / 8.5** (default
8.4), Composer **2.10.1** (pinned), supercronic **v0.2.46**.

### Added

- `patch` APT package: `cweagans/composer-patches` (the de-facto standard for
  applying drupal.org patches) shells out to the `patch` binary during
  `composer install`, which previously failed in this image.
- Commented msmtp configuration template at `/etc/msmtprc` with **no active
  settings**: shared defaults (TLS, stdout logging) plus an SMTP account
  example that reads the password via `passwordeval` from a mounted secret.
  Mail stays unconfigured until the operator uncomments it, mounts a real
  config at the same path, or bakes one into a derived image.
- Composer is now **pinned** via the `COMPOSER_VERSION` build arg (2.10.1) for
  reproducible builds; the GPG signature still verifies every download. Pass
  an empty value to track `latest/download/` instead.
- Self-documenting `make help` target listing every annotated target.

### Changed

- The PHP matrix is single-sourced from the `Makefile`: workflows read it via
  `make print-php-matrix` / `make print-default-php` (rendered as JSON with
  `jq`, consumed via `fromJSON()`), so adding or removing a PHP line is one
  `PHP_VERSIONS` edit.
- The upstream watchers are consolidated into one parameterized `bump` matrix
  job (supercronic and Composer bump PRs) plus a separate `base-image` job
  that opens a heads-up issue on a new `freeunit-php` release.
- Release builds reuse the per-PHP Buildx layer cache from CI; image pushes
  are ordered so floating tags move last.
- CI hardening: shared `ghcr-login` / `trivy-sarif` composite actions, job
  timeouts, stricter Dockerfile ARG extraction, a 7-day Dependabot cooldown
  for action bumps, and `node_modules` excluded from the rumdl markdown lint.
- Smoke test hardening: every toolchain binary is now exercised (not just
  found on `$PATH`), the `sendmail -> msmtp` symlink is asserted, the cron
  app user is centralised behind `SMOKE_APP_USER`, and the web poll bounds
  each probe with `curl --max-time`.

### Fixed

- The upstream watcher's tag validation is anchored with an ERE, so a
  malformed upstream tag can no longer slip through as a partial match.
- The crontab template documents supercronic's sub-minute schedule in the
  correct full 7-field form: a 6-field line is parsed as `min hour dom month
  dow year` (not seconds-first), so the previous examples silently ran
  per-minute.

## [0.1.0] - 2026-06-09

Initial release.

### Added

- Single parameterized `Dockerfile` extending `ghcr.io/6run0/freeunit-php`
  (FreeUnit with embedded PHP on Debian trixie, amd64) with the Drupal runtime
  toolchain: Composer (GPG-verified) and supercronic (version-pinned,
  SHA256-verified). No global Drush; use project-local `vendor/bin/drush`.
- APT packages bundled at build time: `git`, `less`, `mariadb-client`, `msmtp`,
  `openssh-client`, `unzip`; `msmtp` symlinked as `/usr/sbin/sendmail`.
- PHP version matrix: **8.3 / 8.4 / 8.5** (one image per PHP line), driven by
  the `PHP_VER` build arg; defaults to 8.4.
- **Cron role** implemented as an entrypoint hook
  (`rootfs/docker-entrypoint-hook.d/supercronic.sh`): running the image with
  the `supercronic` command activates `handle_supercronic`, which processes
  `/docker-entrypoint.d/*.sh` drop-ins, drops root to the app user via
  `setpriv` (`exec_as_user`), and `exec`s supercronic. The base
  `/docker-entrypoint.sh` is **not** overridden, so every base-entrypoint
  robustness and security fix is inherited automatically.
- Default crontab (`rootfs/etc/supercronic/crontab`) triggering Drupal cron
  via `curl -fsS -o /dev/null "${DRUPAL_CRON_URL:-http://localhost:8080/cron.php}"`
  every 5 minutes; overridable by mounting a custom file at the same path.
- `Makefile` with `all` / `php<X.Y>` / `latest` / `test` / `lint` / `scan`
  targets; per-release defaults (`BASE_IMAGE`, `BASE_TAG`, `PHP_VER`) are
  single-sourced from the `Dockerfile` ARGs.
- CI workflow (`.github/workflows/ci.yml`): lint (hadolint, shellcheck, typos,
  actionlint, zizmor, rumdl), build + smoke test matrix (8.3/8.4/8.5) with
  per-PHP Buildx layer cache, and a report-only trivy scan on the 8.4 leg.
- Documentation: `README.md` / `README.ru.md` (runtime roles, env vars,
  security posture) and `CLAUDE.md` for repository guidance.

[0.3.1]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.3.1
[0.3.0]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.3.0
[0.2.0]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.2.0
[0.1.0]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.1.0
