# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions here track the **packaging** (this repo), not the bundled software; each
release records the base image and PHP versions it ships.

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

[0.1.0]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.1.0
