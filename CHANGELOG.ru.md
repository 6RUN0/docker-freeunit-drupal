# Список изменений

Все значимые изменения проекта документируются в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
проект придерживается [семантического версионирования](https://semver.org/lang/ru/).

Версии здесь относятся к **упаковке** (этому репозиторию), а не к встроенному
ПО; каждый релиз фиксирует версии базового образа и PHP, которые он поставляет.

## [0.1.0] - 2026-06-09

Первый релиз.

### Добавлено

- Единый параметризованный `Dockerfile`, расширяющий `ghcr.io/6run0/freeunit-php`
  (FreeUnit со встроенным PHP на Debian trixie, amd64) рантайм-инструментарием
  для Drupal: Composer (GPG-проверка) и supercronic (закреплён по версии,
  SHA256-проверка). Глобальный Drush не устанавливается; используйте
  проектный `vendor/bin/drush`.
- APT-пакеты, вошедшие в образ при сборке: `git`, `less`, `mariadb-client`,
  `msmtp`, `openssh-client`, `unzip`; `msmtp` симлинкован как
  `/usr/sbin/sendmail`.
- Матрица версий PHP: **8.3 / 8.4 / 8.5** (по одному образу на ветку PHP),
  управляется через build-arg `PHP_VER`; по умолчанию — 8.4.
- **Cron-роль** реализована как хук entrypoint
  (`rootfs/docker-entrypoint-hook.d/supercronic.sh`): запуск образа с командой
  `supercronic` активирует `handle_supercronic`, который обрабатывает `*.sh`
  дроп-ины из `/docker-entrypoint.d/`, сбрасывает root до пользователя
  приложения через `setpriv` (`exec_as_user`) и `exec`-ит supercronic. Базовый
  `/docker-entrypoint.sh` **не переопределяется**, поэтому каждый фикс
  надёжности и безопасности базового entrypoint наследуется автоматически.
- Crontab по умолчанию (`rootfs/etc/supercronic/crontab`), запускающий
  Drupal cron через
  `curl -fsS -o /dev/null "${DRUPAL_CRON_URL:-http://localhost:8080/cron.php}"`
  каждые 5 минут; переопределяется монтированием собственного файла по тому
  же пути.
- `Makefile` с целями `all` / `php<X.Y>` / `latest` / `test` / `lint` /
  `scan`; значения по умолчанию для релиза (`BASE_IMAGE`, `BASE_TAG`, `PHP_VER`)
  единственным источником истины хранятся в ARG-ах `Dockerfile`.
- CI-воркфлоу (`.github/workflows/ci.yml`): линтинг (hadolint, shellcheck,
  typos, actionlint, zizmor, rumdl), сборка + smoke-тест по матрице
  (8.3/8.4/8.5) с per-PHP кэшом слоёв Buildx и report-only trivy-сканом на
  ветке 8.4.
- Документация: `README.md` / `README.ru.md` (роли рантайма, переменные
  окружения, модель безопасности) и `CLAUDE.md` — гайд по репозиторию.

[0.1.0]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.1.0
