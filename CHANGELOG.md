# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions here track the **packaging** (this repo), not the bundled software; each
release records the base image and PHP versions it ships.

## [Unreleased]

### Added

- Opt-in Drupal start-up scripts in `/docker-entrypoint.d/`, each idle until
  its variable is set: `10-freeunit-drupal-writable-dirs.sh`
  (`FREEUNIT_DRUPAL_WRITABLE_DIRS`), `20-freeunit-drupal-msmtp.sh` (writes
  `/run/msmtprc` from `FREEUNIT_DRUPAL_SMTP_*`),
  `30-freeunit-drupal-unit-config.sh` (`FREEUNIT_DRUPAL_UNIT_CONFIG=1`, renders
  a built-in Drupal Unit template or `FREEUNIT_DRUPAL_UNIT_TEMPLATE`) and
  `90-freeunit-drupal-upgrade.sh` (`FREEUNIT_DRUPAL_UPGRADE=1`: wait for the
  database, then `drush cr`, `updb --yes`, `cr` on an installed site). Sites
  stop carrying their own copies of this plumbing; a site script named
  `NNN_*.sh` slots between them in byte order.
- The built-in Unit template returns 404 for the installer, `update.php`,
  `authorize.php`, `rebuild.php`, every PHP file other than `/index.php` (PHP
  under `sites/default/files` never runs) and source and metadata files outside
  the public files dir; under it, the installer's default `config_*/` sync
  directory, `.yml`, `*sql` and the other extensions Drupal's `.htaccess`
  denies. Uploads (`.txt`, `.csv`, `.json`), `/robots.txt` and
  `/.well-known/*` are served.
- Rendering is strict: an undefined `%%NAME%%`, a newline in a value, a `"`,
  `\` or control character in a value of a JSON template, or a result that is
  not JSON stops the start instead of producing a broken configuration.
- `/usr/local/lib/freeunit-drupal/lib.sh` for site scripts:
  `freeunit_drupal_log_*`, `freeunit_drupal_die`,
  `freeunit_drupal_flag_enabled`, `freeunit_drupal_drush`,
  `freeunit_drupal_wait_for_db`.
- `freeunit-drupal-healthcheck` (a site healthcheck through the Unit listener,
  3xx healthy) and `freeunit-drupal-tmp-cleanup` (for a crontab line; `/tmp`
  on disk is emptied by nothing else).
- `freeunit_drupal_wait_for_db` bounds every attempt by the time left, so a
  database host that drops packets cannot hold the start past the limit.
- The compose hardening fragment
  `/usr/local/share/freeunit-drupal/docker-compose.hardening.yml` (service
  `hardened`) and its check
  `/usr/local/share/freeunit-drupal/test/hardening-check.sh` (TAP), to take
  from the image by digest.
- A "Stability" section in the README: the variables, script names, paths and
  library functions above are the public contract from 0.5.0.
- `test/scripts.sh`: TAP tests of the scripts, tools and library, including a
  0.4.0-style site script; `make test` runs it after the smoke test, and so
  does CI for every PHP line.

### Changed

- The web role runs the base entrypoint's configuration round on every start
  with an empty state dir, also when nothing is mounted into
  `/docker-entrypoint.d/`: the directory now holds the image scripts. A start
  takes the round's temporary Unit daemon longer.
- `sendmail_path` of PHP `cli` and `embed` (`05-freeunit-drupal-sendmail.ini`)
  and `/usr/sbin/sendmail` are `/usr/local/bin/freeunit-drupal-sendmail`, not
  `msmtp`. Without `/run/msmtprc` it behaves like msmtp of 0.4.0 (reads
  `/etc/msmtprc`); with it, it uses `/run/msmtprc`. It accepts only the
  options PHP and Drupal pass (`-t`, `-i`, `-oi`, `-f`, `-F`, `--`,
  recipients, `--pretend`, `--version`) and exits 64 on any other; msmtp's exit
  75 (lost message, no queue) becomes 69, so PHP 8.5 `mail()` returns `false`
  like the other lines. A site ini sorted after
  `05-` still wins; a `sendmail_path` in the main `php.ini` of a derived image
  no longer does.
- A directory mounted over `/docker-entrypoint.d/` hides the image scripts
  together with the 0.4.0 contents (nothing); mount single files to keep them.
- CI lint runs `make lint-shell lint-posix LINT_REQUIRE=1`: the file lists come
  from the Makefile, scripts are found by their shebang, and busybox ash checks
  them too.

## [0.4.0] - 2026-11-10

Ships the Debian trixie `freeunit-php` base **0.4.0** pinned by tag and by a
digest per PHP line (FreeUnit `1.37.2-2`), PHP **8.3 / 8.4 / 8.5** (default
8.4), Composer **2.11.1** (pinned), supercronic **v0.2.51**.

Both roles run without root, on the non-root `freeunit-php` 0.4.0 base.
Migration for a derived image or a deployment is the list below.

### Removed

- The `<base-tag>-php<X.Y>` tag that mirrored the substrate: 0.4.0 publishes
  `<version>-php<X.Y>`, `<version>` and `latest` only. The existing
  `trixie-1.37.1-php*` tags stay the root-based 0.3.5 image; move a pin to
  `0.4.0-php<X.Y>@sha256:...`.
- The privilege drop in the cron role: `handle_supercronic` no longer calls
  `exec_as_user` (removed from the base together with `setup_user`), and
  `APPLICATION_USER` / `APPLICATION_GROUP` are ignored. supercronic and its
  jobs run as the container user.

### Changed

- The base moves from `freeunit-php` `trixie-1.37.1` (root, FreeUnit
  `1.37.1-1`) to `0.4.0` (non-root).
- FreeUnit `1.37.1-1` -> `1.37.2-2`, carried by the new base in the same
  release. When a deployment regresses, compare with `freeunit-php` 0.3.0
  first: the same FreeUnit, still root.
- The image starts as `nonroot` (65532:65532) from the first instruction. A
  derived Dockerfile needs `USER 0:0` before its `RUN apt-get ...` and
  `USER 65532:65532` as the last instruction.
- No capability is needed in either role: drop `--cap-add=SETUID
  --cap-add=SETGID` and run `--cap-drop=ALL`. A root start (`--user 0:0`) is
  dropped to 65532 when `CAP_SETUID`, `CAP_SETGID`, `CAP_CHOWN` and `CAP_KILL`
  are present (tini stays root and forwards `docker stop` to the 65532
  processes) and refused otherwise; a non-root uid with group 0 is refused.
- Drop `applications.*.user` / `group` from Unit configs: a non-root Unit
  cannot switch users, runs every worker as its own uid and ignores the keys
  (a config naming another user still applies).
- `/run` (control socket, pid, the Unit state in `/run/freeunit`, generated
  config) and `/tmp` (request bodies, PHP temp files and sessions) must be
  writable for the process uid; with `read_only: true` that is a small tmpfs
  on `/run` and a bind mount on `/tmp`. The state lives in `/run`, so the
  Unit configuration is applied on every start with an empty `/run`. HOME may
  stay read-only.
- Bind mounts the application writes must be writable for the process uid:
  the container changes no ownership.
- A listener below 1024 needs `net.ipv4.ip_unprivileged_port_start=0` (the
  Docker default).
- The control API belongs to the same uid as the PHP workers: code execution
  in PHP can reconfigure Unit until the container restarts.
- `/etc/msmtprc` is not writable for the container user: render a
  configuration into a writable path and pass it with `msmtp -C`, or use
  `~/.msmtprc` with a writable HOME.
- The base is pinned by tag and digest (`BASE_DIGEST_PHP83/84/85` in the
  `Dockerfile`, selected by the `Makefile`); `make` names its builds
  `local-php<X.Y>`. `make` with `BASE_IMAGE` or `BASE_TAG` overridden and no
  `BASE_DIGEST` stops: the table digest would win over the tag and build the
  pinned base.
- `release.yml` refuses to run when an immutable tag (`<version>-php<X.Y>`,
  `<version>`) exists. `<version>` and `latest` move in a separate job, only
  after every PHP leg succeeded, to the attested digest of
  `<version>-php<default>`. `security-scan.yml` scans
  `<latest release>-php<X.Y>` and skips, with a notice, a PHP line the last
  release does not carry; the `check-upstream` base issue lists the new
  `BASE_TAG` and digests.
- Cron role: the hook adds `-no-reap` unless the operator passes it (tini is
  PID 1 and reaps; supercronic no longer logs "process reaping disabled" on
  every start). A trailing argument that is neither a flag nor an existing
  file stops the container with `supercronic crontab not found: ...` instead
  of supercronic's usage text: `supercronic -prometheus-listen-address :9746`
  now needs the crontab path after the value.
- The `supercronic` hook is portable POSIX sh (`#!/bin/sh`, no `local`,
  variables prefixed `supercronic_`), as the base 0.4.0 entrypoint requires:
  it sources hooks into `/bin/sh` (dash), so a bash hook in a derived image
  stops the container at start. `make lint` and CI run `dash -n`.
- The smoke test runs both roles read-only, `--cap-drop=ALL`, as 65532, with
  tmpfs `/run` and `/tmp`, and checks the uid of every process and the logs
  for write and privilege errors; it also runs the cron role as uid 12345
  (no passwd entry), checks the hook is `root:root` and not group/world-writable,
  `-no-reap`, and the refusal of a missing crontab path.

## [0.3.5] - 2026-11-03

Ships the Debian trixie `freeunit-php` base **pinned to `trixie-1.37.1`**
(FreeUnit `1.37.1-1`, base release `v0.2.0`), PHP **8.3 / 8.4 / 8.5** (default
8.4), Composer **2.11.1** (pinned), supercronic **v0.2.51**.

### Changed

- Bump the pinned `freeunit-php` substrate from `trixie-1.36.0-build1` to
  `trixie-1.37.1` (base release `v0.2.0`): the bundled FreeUnit moves from
  `1.36.0-1` to `1.37.1-1`. Upstream dropped the `-buildN` suffix from its
  tags, so the published `<base-tag>-php<X.Y>` tag becomes
  `trixie-1.37.1-php<X.Y>`.
- Bump Composer from `2.10.2` to `2.11.1` and supercronic from `v0.2.47` to
  `v0.2.51` (`SUPERCRONIC_SHA256` recomputed, matches the release asset
  digest).
- CI: bump the SHA-pinned actions (checkout, hadolint, typos, setup-buildx,
  sbom, attest, attest-build-provenance, codeql upload-sarif) and the
  pipx-installed linters (zizmor `1.31.1`, rumdl `0.3.2`). zizmor's new
  `self-repository` audit is disabled in `.github/zizmor.yml`: actionlint does
  not accept the `uses: $/...` form it asks for.
- Dependabot and the `check-upstream` bump PRs target `develop` instead of
  the default branch; `main` only receives fast-forwards from `develop` at
  release time.

## [0.3.4] - 2026-07-17

Ships the Debian trixie `freeunit-php` base **pinned to `trixie-1.36.0-build1`**
(FreeUnit `1.36.0-1`, base release `v0.1.0`), PHP **8.3 / 8.4 / 8.5** (default
8.4), Composer **2.10.2** (pinned), supercronic **v0.2.47**.

### Changed

- Bump the pinned `freeunit-php` substrate from `trixie-1.35.6-build5` to
  `trixie-1.36.0-build1` (base release `v0.1.0`). Unlike the previous
  rebuild-only refreshes, this is a real upstream version bump: the bundled
  FreeUnit moves from `1.35.6-1` to `1.36.0-1`. The published
  `<base-tag>-php<X.Y>` convenience tag follows the substrate.

## [0.3.3] - 2026-07-16

Ships the Debian trixie `freeunit-php` base **pinned to `trixie-1.35.6-build5`**
(FreeUnit `1.35.6-1`, base release `v0.0.9`), PHP **8.3 / 8.4 / 8.5** (default
8.4), Composer **2.10.2** (pinned), supercronic **v0.2.47**.

### Changed

- Bump the pinned `freeunit-php` substrate from `trixie-1.35.6-build4` to
  `trixie-1.35.6-build5` (base release `v0.0.9`). Upstream re-published the
  same FreeUnit `1.35.6-1` package under a new release tag, so the bundled
  FreeUnit and PHP versions are unchanged — a rebuild-only refresh. The
  published `<base-tag>-php<X.Y>` convenience tag follows the substrate.

## [0.3.2] - 2026-07-10

Ships the Debian trixie `freeunit-php` base **pinned to `trixie-1.35.6-build4`**
(FreeUnit `1.35.6-1`, base release `v0.0.8`), PHP **8.3 / 8.4 / 8.5** (default
8.4), Composer **2.10.2** (pinned), supercronic **v0.2.47**.

### Added

- `.trivyignore` listing the HIGH/CRITICAL CVEs with no upstream fix: the
  clusters inherited from the `freeunit-php` base (audited in that repo's
  `.trivyignore`) plus the ones introduced by this image's own APT layer —
  MariaDB server-side CVEs pinned to the client packages (no `mariadbd` /
  `mbstream` shipped; PHP uses the bundled mysqlnd, not libmariadb) and
  sshd-only / hostile-server OpenSSH CVEs (no `sshd` shipped). `make scan`
  and the CI trivy step now surface only new, actionable findings.

### Changed

- Bump supercronic `v0.2.46` -> `v0.2.47` (SHA256 recomputed and verified
  against the release page; built on Go 1.26.4, which clears the two Go
  stdlib DoS findings trivy reported against the static binary) and Composer
  `2.10.1` -> `2.10.2` (GPG-verified at build as before).

- Bump the pinned `freeunit-php` substrate from `trixie-1.35.6-build3` to
  `trixie-1.35.6-build4` (base release `v0.0.8`). Upstream re-published the
  same FreeUnit `1.35.6-1` package under a new release tag, so the bundled
  FreeUnit and PHP versions are unchanged — a rebuild-only refresh. The
  published `<base-tag>-php<X.Y>` convenience tag follows the substrate.

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

[0.4.0]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.4.0
[0.3.5]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.3.5
[0.3.4]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.3.4
[0.3.3]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.3.3
[0.3.2]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.3.2
[0.3.1]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.3.1
[0.3.0]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.3.0
[0.2.0]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.2.0
[0.1.0]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.1.0
