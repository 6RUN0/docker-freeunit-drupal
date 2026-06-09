# FreeUnit + PHP base image, extended with the toolchain a Drupal site needs:
# Composer, a Git/MariaDB/SSH/mail client set, and a supercronic cron runner
# wired in as a SECOND launch mode via the base image's
# entrypoint hook system (no /docker-entrypoint.sh override). The Drupal code
# itself is NOT baked in — it is mounted or composer-installed at runtime; this
# image is the runtime, not the site.
#
# The whole php-version matrix is covered by a single build arg; see the Makefile
# for the matrix build.
#
#   docker build -t freeunit-drupal .                      # defaults: trixie, php8.4
#   docker build --build-arg PHP_VER=8.3 -t freeunit-drupal:8.3 .

# Global build args reachable by the FROM line below. The base image publishes
# one tag per (suite, php) pair, e.g. ghcr.io/6run0/freeunit-php:trixie-php8.4.
# Pin BASE_TAG to a released build (e.g. trixie-1.35.5-build4) for reproducibility.
ARG BASE_IMAGE=ghcr.io/6run0/freeunit-php
ARG BASE_TAG=trixie
ARG PHP_VER=8.4
FROM ${BASE_IMAGE}:${BASE_TAG}-php${PHP_VER}

ARG DEBIAN_FRONTEND=noninteractive

# PHP_VER is a global ARG (declared before FROM), so it is out of scope inside
# this build stage. Re-declare it without a value to pull the global default
# (or any --build-arg override) into scope for the LABEL below. No `=` here, so
# the Makefile's `sed -n 's/^ARG PHP_VER=//p'` keeps single-sourcing the default.
ARG PHP_VER

# supercronic: a crontab-compatible job runner that runs as a single foreground
# process and logs every job to stdout — exactly what a container cron service
# wants (unlike system cron, which daemonizes and logs to syslog). Pinned by
# version + SHA256 and verified on download, mirroring how the base image fetches
# its own release assets. amd64 only, matching the base image's platform.
ARG SUPERCRONIC_VERSION=v0.2.46
ARG SUPERCRONIC_SHA256=5adff01c5a797663948e656d2b61d10932369ee437eb5cb54fa872b2960f222b

# Composer's release signing key — the verified GPG fingerprint, not a URL and
# not a secret. Named *_FINGERPRINT rather than *_KEY so BuildKit's
# SecretsUsedInArgOrEnv heuristic (which trips on KEY/SECRET/TOKEN/PASSWORD in an
# ARG/ENV name) does not flag this public identifier.
ARG COMPOSER_GPG_FINGERPRINT=161DFBE342889F01DDAC4E61CBB3D576F2A0946F

# Composer release to install, pinned for a reproducible image: the GPG signature
# below guarantees authenticity, this pin guarantees the version (two builds on
# different days embed the same Composer). Bumped automatically by the
# check-upstream workflow; set to empty to track latest/ instead.
ARG COMPOSER_VERSION=2.10.1

# DL3008: rolling apt repos (Debian + sury) — pinning every package version is
#   impractical. DL3003: `cd /usr/local/bin` is the deliberate download target for
#   the fetched tools, not a WORKDIR for the image. SC2086: $savedAptMark must
#   word-split into one arg per package to re-mark the base's manual set.
# hadolint ignore=DL3008,DL3003,SC2086
RUN \
    set -eux; \
    # Shared download helper: bundle the common curl flags (fail on HTTP errors,
    # follow redirects, retry transient/connection failures, refuse any non-HTTPS
    # redirect) and forward the rest verbatim, so each call keeps curl's own
    # `-o <file> <url>` syntax. Used for every release asset below (Composer phar
    # + signature, supercronic binary).
    fetch() { curl -fsSL --retry 3 --retry-connrefused --proto-redir '=https' "$@"; }; \
    # Remember which packages were manually installed by the base image so the
    # build-only deps (gnupg/dirmngr, needed to verify Composer's signature) can
    # be auto-removed afterwards without dragging the base's packages with them.
    savedAptMark="$(apt-mark showmanual)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends dirmngr gnupg; \
    apt-mark auto '.*' > /dev/null; \
    [ -z "$savedAptMark" ] || apt-mark manual $savedAptMark > /dev/null; \
    # --- Composer (release phar, GPG-verified against the pinned key) ----------
    cd /usr/local/bin; \
    # Pin a specific Composer release when COMPOSER_VERSION is set, else track latest.
    if [ -n "$COMPOSER_VERSION" ]; then composerRelease="download/${COMPOSER_VERSION}"; \
    else composerRelease="latest/download"; fi; \
    fetch -o composer "https://github.com/composer/composer/releases/${composerRelease}/composer.phar"; \
    fetch -o composer.asc "https://github.com/composer/composer/releases/${composerRelease}/composer.phar.asc"; \
    GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; \
    gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$COMPOSER_GPG_FINGERPRINT"; \
    gpg --batch --verify composer.asc composer; \
    gpgconf --kill all; \
    rm -rf "$GNUPGHOME" composer.asc; \
    chmod 0755 composer; \
    # --- supercronic (pinned + SHA256-verified) -------------------------------
    fetch -o supercronic \
        "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64"; \
    # String test rather than a pipe into `sha256sum -c`, to keep the RUN free of
    # pipes (hadolint DL4006) — `sha256sum FILE` prints "<hash>  FILE".
    [ "$(sha256sum supercronic)" = "${SUPERCRONIC_SHA256}  supercronic" ] \
    || { echo "ERROR: supercronic digest does not match the pinned SUPERCRONIC_SHA256"; exit 1; }; \
    chmod 0755 supercronic; \
    # --- Runtime packages -----------------------------------------------------
    # Why each one is here:
    #   git, openssh-client - pull/deploy the site's config (YAML) and code over
    #                         SSH-authenticated git remotes.
    #   mariadb-client      - reach the database for maintenance and inspection;
    #   less                - its pager, so `SELECT ... \G` output stays readable.
    #   msmtp               - SMTP sendmail drop-in for PHP mail() (symlinked as
    #                         /usr/sbin/sendmail below).
    #   unzip               - Composer extracts package archives with it.
    # No gosu/su-exec: the base image drops privileges with setpriv via the
    # exec_as_user library helper, used by the cron hook below.
    apt-get install -y --no-install-recommends \
    git \
    less \
    mariadb-client \
    msmtp \
    openssh-client \
    unzip \
    ; \
    # Drop the build-only deps (gnupg/dirmngr et al.) marked auto above.
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    apt-get clean; \
    rm -rf \
    /var/cache/apt/archives/* \
    /var/lib/apt/lists/* \
    /var/log/alternatives.log \
    /var/log/apt* \
    /var/log/dpkg.log \
    ; \
    # Route PHP mail through msmtp by presenting it as /usr/sbin/sendmail.
    ln -sf /usr/bin/msmtp /usr/sbin/sendmail; \
    # Prove the toolchain loaded.
    composer --version; \
    supercronic -version; \
    git --version; \
    msmtp --version; \
    mariadb --version; \
    unzip -v > /dev/null

# rootfs/ mirrors the container filesystem: the supercronic entrypoint hook
# (/docker-entrypoint-hook.d/supercronic.sh) and the default crontab
# (/etc/supercronic/crontab). The hook is owned root:root and not world-writable
# (COPY default), as the base dispatcher's assert_safe_root_file requires.
COPY rootfs/ /

LABEL org.opencontainers.image.title="freeunit-drupal" \
      org.opencontainers.image.description="FreeUnit (NGINX Unit fork) with embedded PHP ${PHP_VER} and the Drupal runtime toolchain (Composer, supercronic, git, mariadb-client, msmtp) on Debian" \
      org.opencontainers.image.source="https://github.com/6RUN0/docker-freeunit-drupal" \
      org.opencontainers.image.url="https://github.com/6RUN0/docker-freeunit-drupal" \
      org.opencontainers.image.licenses="BSD-3-Clause"
