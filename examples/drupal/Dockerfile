# Site image of the example: the Drupal code, its settings, recipes and
# crontab are built in, the data directories are volumes. The tag below is
# immutable by the release policy of freeunit-drupal; a real site pins the
# digest too (README, "Pins").
FROM ghcr.io/6run0/freeunit-drupal:0.5.0-php8.4

# composer and the data directories need root; the last instruction switches
# back to the image user.
USER 0:0

WORKDIR /www

# Dependencies first, from the lock only: a change of the site code reuses
# this layer. The cache mount keeps downloads out of the image.
COPY composer.json composer.lock ./
RUN --mount=type=cache,target=/var/cache/composer \
    COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_CACHE_DIR=/var/cache/composer \
    composer validate --no-check-publish --no-interaction \
    && COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_CACHE_DIR=/var/cache/composer \
    composer install --no-dev --no-interaction --no-progress --no-scripts --no-autoloader

# The site files, then the scaffold and the autoloader without network: every
# package is in vendor already. The code stays root-owned and read-only;
# only the public and private files directories belong to the run uid.
COPY crontab /etc/supercronic/crontab
COPY config/ config/
COPY recipes/ recipes/
COPY web/ web/
RUN --network=none \
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --no-interaction --no-progress --optimize-autoloader \
    && install -d -o 65532 -g 65532 -m 0750 web/sites/default/files private

ENV PATH=/www/vendor/bin:$PATH \
    FREEUNIT_DRUPAL_UNIT_CONFIG=1 \
    FREEUNIT_DRUPAL_WRITABLE_DIRS="web/sites/default/files private"

USER 65532:65532
