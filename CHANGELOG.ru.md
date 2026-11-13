# Список изменений

Все значимые изменения проекта документируются в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
проект придерживается [семантического версионирования](https://semver.org/lang/ru/).

Версии здесь относятся к **упаковке** (этому репозиторию), а не к встроенному
ПО; каждый релиз фиксирует версии базового образа и PHP, которые он поставляет.

## [Unreleased]

### Добавлено

- Стартовые скрипты Drupal в `/docker-entrypoint.d/`, каждый включается явно и
  без своей переменной ничего не делает: `10-freeunit-drupal-writable-dirs.sh`
  (`FREEUNIT_DRUPAL_WRITABLE_DIRS`), `20-freeunit-drupal-msmtp.sh` (пишет
  `/run/msmtprc` из `FREEUNIT_DRUPAL_SMTP_*`),
  `30-freeunit-drupal-unit-config.sh` (`FREEUNIT_DRUPAL_UNIT_CONFIG=1`,
  рендерит встроенный шаблон Unit для Drupal или `FREEUNIT_DRUPAL_UNIT_TEMPLATE`)
  и `90-freeunit-drupal-upgrade.sh` (`FREEUNIT_DRUPAL_UPGRADE=1`: ждёт базу
  данных, затем на установленном сайте `drush cr`, `updb --yes`, `cr`). Сайты
  перестают держать свои копии этой обвязки; скрипт сайта `NNN_*.sh` встаёт
  между ними в байтовом порядке.
- Встроенный шаблон Unit отвечает 404 на установщик, `update.php`,
  `authorize.php`, `rebuild.php`, любой PHP-файл, кроме `/index.php` (PHP из
  `sites/default/files` не исполняется никогда), и на исходники и служебные
  файлы вне публичного каталога файлов; под ним - на каталог синхронизации
  `config_*/` установщика по умолчанию, `.yml`, `*sql` и прочие расширения,
  которые запрещает `.htaccess` Drupal. Загрузки (`.txt`, `.csv`, `.json`),
  `/robots.txt` и `/.well-known/*` отдаются.
- Рендер строгий: неопределённый `%%ИМЯ%%`, перевод строки в значении, `"`,
  `\` или управляющий символ в значении JSON-шаблона, результат, не
  являющийся JSON, останавливают старт, а не дают сломанную конфигурацию.
- `/usr/local/lib/freeunit-drupal/lib.sh` для скриптов сайта:
  `freeunit_drupal_log_*`, `freeunit_drupal_die`,
  `freeunit_drupal_flag_enabled`, `freeunit_drupal_drush`,
  `freeunit_drupal_wait_for_db`.
- `freeunit-drupal-healthcheck` (healthcheck сайта через слушатель Unit, 3xx -
  здоров) и `freeunit-drupal-tmp-cleanup` (для строки crontab; `/tmp` на диске
  больше никто не чистит).
- `freeunit_drupal_wait_for_db` ограничивает каждую попытку оставшимся
  временем, поэтому хост базы, теряющий пакеты, не держит старт дольше предела.
- Фрагмент усиления compose
  `/usr/local/share/freeunit-drupal/docker-compose.hardening.yml` (сервис
  `hardened`) и его проверка
  `/usr/local/share/freeunit-drupal/test/hardening-check.sh` (TAP), которую
  берут из образа по digest.
- Раздел "Стабильность" в README: переменные, имена скриптов, пути и функции
  библиотеки выше - публичный контракт с 0.5.0.
- `test/scripts.sh`: TAP-тесты скриптов, утилит и библиотеки, в том числе со
  скриптом сайта в стиле 0.4.0; `make test` запускает его после smoke-теста,
  CI - для каждой ветки PHP.

### Изменено

- Веб-роль выполняет раунд начальной конфигурации базового entrypoint на
  каждом старте с пустым каталогом состояния, даже если в
  `/docker-entrypoint.d/` ничего не смонтировано: теперь там лежат скрипты
  образа. Старт дольше на время временного демона Unit этого раунда.
- `sendmail_path` PHP `cli` и `embed` (`05-freeunit-drupal-sendmail.ini`) и
  `/usr/sbin/sendmail` - это `/usr/local/bin/freeunit-drupal-sendmail`, а не
  `msmtp`. Без `/run/msmtprc` обёртка ведёт себя как msmtp из 0.4.0 (читает
  `/etc/msmtprc`), с ним - берёт `/run/msmtprc`. Она принимает только
  параметры, которые передают PHP и Drupal (`-t`, `-i`, `-oi`, `-f`, `-F`, `--`,
  получатели, `--pretend`, `--version`), на любом другом - код 64; код 75 msmtp
  (письмо потеряно, очереди нет) становится 69, поэтому `mail()` PHP 8.5
  возвращает `false`, как и на других ветках. ini сайта,
  который сортируется после `05-`, по-прежнему перекрывает значение;
  `sendmail_path` в главном `php.ini` производного образа - больше нет.
- Каталог, смонтированный поверх `/docker-entrypoint.d/`, прячет скрипты
  образа вместе с содержимым 0.4.0 (пустым); чтобы их сохранить, монтируйте
  отдельные файлы.
- Lint в CI запускает `make lint-shell lint-posix LINT_REQUIRE=1`: списки
  файлов берутся из Makefile, скрипты находятся по shebang и проверяются ещё и
  busybox ash.

## [0.4.0] - 2026-11-10

Поставляется на базе `freeunit-php` (Debian trixie) **0.4.0**, закреплённой
тегом и digest по каждой ветке PHP (FreeUnit `1.37.2-2`), PHP **8.3 / 8.4 /
8.5** (по умолчанию 8.4), Composer **2.11.1** (закреплён), supercronic
**v0.2.51**.

Обе роли работают без root, на базе `freeunit-php` 0.4.0 без root. Переход для
производного образа или развёртывания - список ниже.

### Удалено

- Тег `<base-tag>-php<X.Y>`, зеркало подложки: 0.4.0 публикует только
  `<версия>-php<X.Y>`, `<версия>` и `latest`. Существующие теги
  `trixie-1.37.1-php*` остаются образом 0.3.5 от root; переведите пин на
  `0.4.0-php<X.Y>@sha256:...`.
- Сброс привилегий в cron-роли: `handle_supercronic` больше не вызывает
  `exec_as_user` (удалён из базы вместе с `setup_user`), `APPLICATION_USER` /
  `APPLICATION_GROUP` игнорируются. supercronic и его задачи работают от
  пользователя контейнера.

### Изменено

- База переходит с `freeunit-php` `trixie-1.37.1` (root, FreeUnit `1.37.1-1`)
  на `0.4.0` (без root).
- FreeUnit `1.37.1-1` -> `1.37.2-2` приходит с новой базой в том же релизе.
  При регрессии развёртывания сначала сравните с `freeunit-php` 0.3.0: тот же
  FreeUnit, ещё от root.
- Образ стартует от `nonroot` (65532:65532) с первой инструкции. Производному
  Dockerfile нужен `USER 0:0` перед `RUN apt-get ...` и `USER 65532:65532`
  последней инструкцией.
- Capabilities не нужны ни одной роли: уберите `--cap-add=SETUID
  --cap-add=SETGID` и запускайте с `--cap-drop=ALL`. Запуск от root
  (`--user 0:0`) сбрасывается на 65532 при наличии `CAP_SETUID`, `CAP_SETGID`,
  `CAP_CHOWN` и `CAP_KILL` (tini остаётся root и пересылает `docker stop`
  процессам 65532), иначе отвергается; не-root uid с группой 0 отвергается.
- Уберите `applications.*.user` / `group` из конфигов Unit: Unit без root не
  может сменить пользователя, запускает все воркеры своим uid и игнорирует
  эти ключи (конфиг с другим пользователем всё равно применяется).
- `/run` (управляющий сокет, pid, состояние Unit в `/run/freeunit`,
  сгенерированная конфигурация) и `/tmp` (тела запросов, временные файлы и
  сессии PHP) должны быть доступны для записи uid процесса; при
  `read_only: true` это маленький tmpfs на `/run` и bind mount на `/tmp`.
  Состояние живёт в `/run`, поэтому конфигурация Unit применяется при каждом
  старте с пустым `/run`. HOME может быть только для чтения.
- Bind mount, в которые пишет приложение, должны быть доступны для записи uid
  процесса: контейнер владельцев не меняет.
- Слушателю на порту ниже 1024 нужен `net.ipv4.ip_unprivileged_port_start=0`
  (умолчание Docker).
- Control API принадлежит тому же uid, что PHP-воркеры: выполнение кода в PHP
  может перенастроить Unit до перезапуска контейнера.
- `/etc/msmtprc` пользователю контейнера недоступен для записи: рендерите
  конфигурацию в доступный для записи путь и передавайте её через `msmtp -C`
  или используйте `~/.msmtprc` при доступном для записи HOME.
- База закреплена тегом и digest (`BASE_DIGEST_PHP83/84/85` в `Dockerfile`,
  выбирает `Makefile`); `make` называет свои сборки `local-php<X.Y>`. `make` с
  переопределёнными `BASE_IMAGE` или `BASE_TAG` и без `BASE_DIGEST`
  останавливается: digest таблицы победил бы тег и собрал закреплённую базу.
- `release.yml` отказывается работать, если неизменяемый тег
  (`<версия>-php<X.Y>`, `<версия>`) уже есть. `<версия>` и `latest` переносятся
  отдельным job только после успеха всех веток PHP, на аттестованный digest
  `<версия>-php<по умолчанию>`. `security-scan.yml` сканирует
  `<последний релиз>-php<X.Y>` и с notice пропускает ветку PHP, которой нет в
  последнем релизе; issue `check-upstream` о новой базе содержит новые
  `BASE_TAG` и digest.
- Cron-роль: хук добавляет `-no-reap`, если оператор его не передал (PID 1 -
  tini, он и собирает процессы; supercronic больше не пишет "process reaping
  disabled" при каждом старте). Завершающий аргумент, который не флаг и не
  существующий файл, останавливает контейнер с
  `supercronic crontab not found: ...` вместо справки supercronic:
  `supercronic -prometheus-listen-address :9746` теперь требует путь к crontab
  после значения.
- Хук `supercronic` написан на переносимом POSIX sh (`#!/bin/sh`, без
  `local`, переменные с префиксом `supercronic_`), как требует entrypoint базы
  0.4.0: он подключает хуки в `/bin/sh` (dash), и bash-хук производного образа
  останавливает контейнер при старте. `make lint` и CI запускают `dash -n`.
- smoke-тест запускает обе роли только для чтения, с `--cap-drop=ALL`, от
  65532, с tmpfs `/run` и `/tmp` и проверяет uid каждого процесса и логи на
  ошибки записи и привилегий; ещё он запускает cron-роль от uid 12345 (без
  записи passwd), проверяет, что хук `root:root` и без записи для группы/всех,
  `-no-reap` и отказ при отсутствующем crontab.

## [0.3.5] - 2026-11-03

Поставляется на базе `freeunit-php` (Debian trixie), **закреплённой на сборке
`trixie-1.37.1`** (FreeUnit `1.37.1-1`, релиз базы `v0.2.0`),
PHP **8.3 / 8.4 / 8.5** (по умолчанию 8.4), Composer **2.11.1** (закреплён),
supercronic **v0.2.51**.

### Изменено

- Пин базового образа `freeunit-php` поднят с `trixie-1.36.0-build1` до
  `trixie-1.37.1` (релиз базы `v0.2.0`): встроенный FreeUnit обновляется с
  `1.36.0-1` до `1.37.1-1`. Upstream убрал суффикс `-buildN` из тегов, поэтому
  публикуемый тег `<base-tag>-php<X.Y>` становится `trixie-1.37.1-php<X.Y>`.
- Composer поднят с `2.10.2` до `2.11.1`, supercronic - с `v0.2.47` до
  `v0.2.51` (`SUPERCRONIC_SHA256` пересчитан и совпадает с digest ассета
  релиза).
- CI: обновлены закреплённые по SHA actions (checkout, hadolint, typos,
  setup-buildx, sbom, attest, attest-build-provenance, codeql upload-sarif) и
  линтеры, ставящиеся через pipx (zizmor `1.31.1`, rumdl `0.3.2`). Новый
  аудит zizmor `self-repository` отключён в `.github/zizmor.yml`: actionlint
  не принимает форму `uses: $/...`, которой он требует.
- PR от Dependabot и `check-upstream` открываются в `develop`, а не в ветку по
  умолчанию; `main` получает только fast-forward из `develop` при релизе.

## [0.3.4] - 2026-07-17

Поставляется на базе `freeunit-php` (Debian trixie), **закреплённой на сборке
`trixie-1.36.0-build1`** (FreeUnit `1.36.0-1`, релиз базы `v0.1.0`),
PHP **8.3 / 8.4 / 8.5** (по умолчанию 8.4), Composer **2.10.2** (закреплён),
supercronic **v0.2.47**.

### Изменено

- Пин базового образа `freeunit-php` поднят с `trixie-1.35.6-build5` до
  `trixie-1.36.0-build1` (релиз базы `v0.1.0`). В отличие от прошлых
  rebuild-only обновлений это реальный бамп версии upstream: встроенный
  FreeUnit обновляется с `1.35.6-1` до `1.36.0-1`. Публикуемый base-тег
  `<base-tag>-php<X.Y>` следует за подложкой.

## [0.3.3] - 2026-07-16

Поставляется на базе `freeunit-php` (Debian trixie), **закреплённой на сборке
`trixie-1.35.6-build5`** (FreeUnit `1.35.6-1`, релиз базы `v0.0.9`),
PHP **8.3 / 8.4 / 8.5** (по умолчанию 8.4), Composer **2.10.2** (закреплён),
supercronic **v0.2.47**.

### Изменено

- Пин базового образа `freeunit-php` поднят с `trixie-1.35.6-build4` до
  `trixie-1.35.6-build5` (релиз базы `v0.0.9`). Upstream переиздал тот же
  пакет FreeUnit `1.35.6-1` под новым тегом релиза, поэтому версии FreeUnit и
  PHP не изменились — это rebuild-only обновление. Публикуемый
  base-тег `<base-tag>-php<X.Y>` следует за подложкой.

## [0.3.2] - 2026-07-10

Поставляется на базе `freeunit-php` (Debian trixie), **закреплённой на сборке
`trixie-1.35.6-build4`** (FreeUnit `1.35.6-1`, релиз базы `v0.0.8`),
PHP **8.3 / 8.4 / 8.5** (по умолчанию 8.4), Composer **2.10.2** (закреплён),
supercronic **v0.2.47**.

### Добавлено

- `.trivyignore` со списком HIGH/CRITICAL CVE без доступного исправления:
  кластеры, унаследованные от базы `freeunit-php` (проаудированы в
  `.trivyignore` того репозитория), плюс внесённые APT-слоем этого образа —
  серверные CVE MariaDB, приписанные клиентским пакетам (в образе нет
  `mariadbd` / `mbstream`; PHP использует встроенный mysqlnd, а не
  libmariadb) и sshd-only / hostile-server CVE OpenSSH (в образе нет `sshd`).
  `make scan` и trivy-шаг CI теперь показывают только новые, требующие
  действия находки.

### Изменено

- supercronic поднят `v0.2.46` -> `v0.2.47` (SHA256 пересчитан и сверен со
  страницей релиза; собран на Go 1.26.4, что убирает две DoS-находки Go
  stdlib, которые trivy показывал на статическом бинарнике) и Composer
  `2.10.1` -> `2.10.2` (как и прежде, GPG-проверка при сборке).

- Закреплённая подложка `freeunit-php` поднята с `trixie-1.35.6-build3` до
  `trixie-1.35.6-build4` (релиз базы `v0.0.8`). Upstream переиздал тот же
  пакет FreeUnit `1.35.6-1` под новым тегом релиза, поэтому версии FreeUnit и
  PHP не изменились — это rebuild-only обновление. Публикуемый
  base-тег `<base-tag>-php<X.Y>` следует за подложкой.

## [0.3.1] - 2026-06-28

Поставляется на базе `freeunit-php` (Debian trixie), **закреплённой на сборке
`trixie-1.35.6-build3`** (FreeUnit `1.35.6-1`, релиз базы `v0.0.7`),
PHP **8.3 / 8.4 / 8.5** (по умолчанию 8.4), Composer **2.10.1** (закреплён),
supercronic **v0.2.46**.

### Изменено

- Подложка `freeunit-php` закреплена: `BASE_TAG` теперь по умолчанию указывает
  на выпущенную сборку `trixie-1.35.6-build3` вместо плавающего suite-тега
  `trixie`, поэтому релиз собирается на известной базе, а пересборка git-тега
  воспроизводима. Публикуемый base-тег следует за подложкой
  (`:trixie-1.35.6-build3-php8.4`); потребительские теги `:latest`,
  `:<версия>` и `:<версия>-php<X.Y>` не меняются. Переопределите через
  `--build-arg BASE_TAG=trixie` (или `make BASE_TAG=trixie …`), чтобы локально
  следовать плавающей подложке. Закреплённая база — это rebuild-only обновление
  прежнего пакета `1.35.6-1` (без смены версии FreeUnit или PHP).

## [0.3.0] - 2026-06-22

Поставляется на базе `freeunit-php` (Debian trixie, теперь ребрендированной --
демон `freeunitd`, пользователь приложения `freeunit`, база `v0.0.6`+),
PHP **8.3 / 8.4 / 8.5** (по умолчанию 8.4), Composer **2.10.1** (закреплён),
supercronic **v0.2.46**.

### Изменено

- Конфигурация и тесты приведены в соответствие с ребрендингом `unit` ->
  `freeunit` в базовом образе `freeunit-php` (база `v0.0.6`): бинарь демона
  теперь `freeunitd`, а пользователь/группа приложения по умолчанию —
  `freeunit`. В примере и фикстуре `config.json` PHP-воркеры запускаются как
  `freeunit:freeunit`, а значение пользователя по умолчанию в smoke-тесте
  следует новому имени (по-прежнему переопределяется через `SMOKE_APP_USER`).
  Путь образа (`ghcr.io/6run0/freeunit-php`) не изменился.
- Расширена проверка при сборке и в smoke-тесте: блок `--version` тулчейна в
  Dockerfile и smoke-тест теперь задействуют `ssh` (openssh-client) и `less` --
  две документированные runtime-зависимости, которые раньше не проверялись.
  Smoke-тест также утверждает, что отданная версия PHP соответствует тестируемой
  ветке и -- зеркало существующей cron-проверки для web-роли -- что PHP-воркер
  исполняется под пользователем приложения (`freeunit`), а не root.

## [0.2.0] - 2026-06-10

Поставляется на базе `freeunit-php` (Debian trixie), PHP **8.3 / 8.4 / 8.5**
(по умолчанию 8.4), Composer **2.10.1** (закреплён), supercronic **v0.2.46**.

### Добавлено

- APT-пакет `patch`: `cweagans/composer-patches` (де-факто стандарт применения
  патчей с drupal.org) вызывает бинарь `patch` во время `composer install`,
  что раньше в этом образе завершалось ошибкой.
- Закомментированный шаблон конфигурации msmtp в `/etc/msmtprc` **без активных
  настроек**: общие значения по умолчанию (TLS, лог в stdout) плюс пример
  SMTP-аккаунта, читающий пароль через `passwordeval` из смонтированного
  секрета. Почта остаётся ненастроенной, пока оператор не раскомментирует
  шаблон, не смонтирует свой конфиг по тому же пути или не запечёт его в
  производный образ.
- Composer теперь **закреплён** через build-arg `COMPOSER_VERSION` (2.10.1)
  для воспроизводимых сборок; GPG-подпись по-прежнему проверяется при каждой
  загрузке. Передайте пустое значение, чтобы следовать `latest/download/`.
- Самодокументируемая цель `make help`, перечисляющая все аннотированные цели.

### Изменено

- Матрица PHP имеет единственный источник истины — `Makefile`: воркфлоу
  читают её через `make print-php-matrix` / `make print-default-php` (JSON
  формируется через `jq` и потребляется через `fromJSON()`), так что
  добавление или удаление ветки PHP — одна правка `PHP_VERSIONS`.
- Наблюдатели за апстримом объединены в одну параметризованную матричную
  джобу `bump` (PR-ы с бампами supercronic и Composer) плюс отдельную джобу
  `base-image`, открывающую issue-уведомление о новом релизе `freeunit-php`.
- Релизные сборки переиспользуют per-PHP кэш слоёв Buildx из CI; пуш образов
  упорядочен так, что плавающие теги передвигаются последними.
- Усиление CI: общие композитные действия `ghcr-login` / `trivy-sarif`,
  таймауты джоб, более строгое извлечение ARG-ов из Dockerfile, 7-дневный
  cooldown Dependabot для бампов actions и исключение `node_modules` из
  markdown-линта rumdl.
- Усиление smoke-теста: каждый бинарь тулчейна теперь реально запускается
  (а не только ищется в `$PATH`), проверяется симлинк `sendmail -> msmtp`,
  пользователь приложения cron-роли централизован за `SMOKE_APP_USER`, а
  каждый опрос веб-роли ограничен `curl --max-time`.

### Исправлено

- Валидация тега апстрима в наблюдателе заякорена ERE-выражением, так что
  некорректный тег апстрима больше не проходит частичным совпадением.
- Шаблон crontab документирует субминутное расписание supercronic в корректной
  полной 7-полевой форме: строка из 6 полей разбирается как `min hour dom
  month dow year` (а не «секунды первым полем»), поэтому прежние примеры
  молча выполнялись раз в минуту.

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

[0.4.0]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.4.0
[0.3.5]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.3.5
[0.3.4]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.3.4
[0.3.3]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.3.3
[0.3.2]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.3.2
[0.3.1]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.3.1
[0.3.0]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.3.0
[0.2.0]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.2.0
[0.1.0]: https://github.com/6RUN0/docker-freeunit-drupal/releases/tag/v0.1.0
