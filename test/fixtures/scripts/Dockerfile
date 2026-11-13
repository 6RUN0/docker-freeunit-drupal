# Site images of test/scripts.sh, built FROM the image under test the way a
# site builds its own: the code and the site scripts are COPYed in, the
# scripts with the execute bit, nothing runs as root. Target site: scripts
# 000_, 500_, 999_ around those of the image; target compat: a 0.4.0-style
# 000_configure.sh.
ARG IMAGE=freeunit-drupal:local-php8.4

FROM ${IMAGE} AS common
COPY www/ /www/
COPY templates/ /fixtures/templates/
COPY compat/ /fixtures/compat/
COPY etc-msmtprc smtp_password /fixtures/

FROM common AS site
COPY --chmod=0755 site.d/ /docker-entrypoint.d/

FROM common AS compat
COPY --chmod=0755 compat.d/ /docker-entrypoint.d/
