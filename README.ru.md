# Рантайм-образ для Drupal на основе freeunit-php

[English](README.md) · [Русский](README.ru.md) — историю релизов смотрите в
[CHANGELOG.ru.md](CHANGELOG.ru.md).

Репозиторий собирает Docker-образы, расширяющие
[`ghcr.io/6run0/freeunit-php`](https://github.com/6RUN0/docker-freeunit-php)
(FreeUnit — форк NGINX Unit — со встроенным модулем PHP) инструментарием,
необходимым сайту Drupal в рантайме.

Что этот образ добавляет поверх базового:

- **Composer** — загружается как `.phar` и проверяется по закреплённому
  [GPG-ключу мейнтейнеров Composer](https://getcomposer.org/download/)
  (ключ `161DFBE342889F01DDAC4E61CBB3D576F2A0946F`).
- **supercronic** — crontab-совместимый cron-раннер переднего плана,
  закреплённый по версии и проверенный по SHA256, подключённый как второй
  режим запуска через систему хуков entrypoint базового образа.
- **APT-пакеты** для рантайма Drupal: `git` + `openssh-client` (выгрузка и
  деплой конфигурации и кода через git по SSH), `mariadb-client` + `less`
  (работа с базой данных, например `SELECT … \G` через пейджер), `msmtp`
  (SMTP-замена `sendmail`, симлинкована как `/usr/sbin/sendmail`, чтобы `mail()`
  PHP работал из коробки), `patch` (чтобы `cweagans/composer-patches` мог
  накладывать патчи с drupal.org во время `composer install`) и `unzip`
  (распаковка архивов пакетов Composer).

Код приложения Drupal **не** запекается в образ. Он монтируется или
устанавливается Composer'ом в рантайме. Этот образ — среда выполнения,
а не сайт.

- **Базовый образ:** `ghcr.io/6run0/freeunit-php` 0.4.0 (trixie, amd64),
  закреплён тегом и digest
- **Пользователь:** непривилегированный `nonroot` (65532:65532) с первой
  инструкции, в обеих ролях; см. [Запуск без root](#запуск-без-root)
- **Версии PHP:** 8.3, 8.4, 8.5 (по одному образу на ветку PHP)
- **Дистрибутив:** Debian **trixie**, только amd64

Единый параметризованный `Dockerfile` покрывает всю матрицу через build-args;
`Makefile` собирает каждый вариант.

## Получение образа

Готовые образы публикуются в GitHub Container Registry по адресу
`ghcr.io/6run0/freeunit-drupal`. Каждый релиз публикует по одному образу на
каждую ветку PHP (8.3 / 8.4 / 8.5) под несколькими тегами:

| Шаблон тега | Пример | Указывает на |
|-------------|--------|--------------|
| `latest` | `ghcr.io/6run0/freeunit-drupal` | свежий релиз, PHP по умолчанию (8.4) |
| `<версия>` | `:0.4.0` | этот релиз репозитория, PHP по умолчанию |
| `<версия>-php<X.Y>` | `:0.4.0-php8.4` | конкретный релиз на ветке PHP |

```bash
docker pull ghcr.io/6run0/freeunit-drupal:0.4.0-php8.4
```

Тег `latest` плавающий - указывает на свежий релиз (PHP по умолчанию). Теги
`<версия>` и `<версия>-php<X.Y>` неизменяемы: воркфлоу релиза отказывается
перезаписывать существующий. Развёртывание закрепляйте по digest
(`:0.4.0-php8.4@sha256:...`). Релизы до 0.3.5 публиковали ещё тег
`<base-tag>-php<X.Y>`, зеркало подложки (например `:trixie-1.37.1-php8.4`,
образ от root); 0.4.0 таких тегов не публикует, существующие не трогает.

## Сборка

Воспроизводимая сборка - через Makefile: он закрепляет базу по digest.

```bash
make                                        # собрать все версии PHP (8.3, 8.4, 8.5)
make php8.3                                 # собрать один вариант -> freeunit-drupal:local-php8.3
make latest                                 # собрать PHP по умолчанию (8.4) и пометить :latest
make test                                   # собрать PHP по умолчанию и прогнать smoke-тест
make lint                                   # запустить все установленные линтеры
make scan                                   # CVE-скан образа по умолчанию (если есть trivy/grype)
make BASE_TAG=trixie BASE_DIGEST= php8.4    # использовать плавающую подложку
```

`local-php<X.Y>` - локальный тег сборки, он никогда не публикуется.

Простой `docker build` тянет базу только по тегу, без digest:

```bash
docker build -t freeunit-drupal .                                  # база 0.4.0, php8.4
docker build --build-arg PHP_VER=8.3 -t freeunit-drupal:8.3 .
docker build --build-arg BASE_TAG=trixie -t freeunit-drupal .     # плавающий suite-тег
```

Значения по умолчанию (`BASE_IMAGE`, `BASE_TAG`, `PHP_VER`) и digest базы для
каждой ветки PHP (`BASE_DIGEST_PHP83`, `BASE_DIGEST_PHP84`, `BASE_DIGEST_PHP85`)
хранятся в ARG-ах `Dockerfile`. `Makefile` читает их оттуда и передаёт digest
собираемой ветки как `BASE_DIGEST`; пустая запись таблицы останавливает
сборку. При переопределении `BASE_IMAGE` или `BASE_TAG` нужен и `BASE_DIGEST`
(пустой - только по тегу), иначе `make` останавливается: digest таблицы
победил бы тег. Обновление базы - `BASE_TAG` и три digest, всё в `Dockerfile`; каждый
читается командой
`docker buildx imagetools inspect ghcr.io/6run0/freeunit-php:<версия>-php<X.Y>`.
В ARG-ах `Dockerfile` закреплены ещё два ассета: `supercronic` (версия +
SHA256) и Composer (`COMPOSER_VERSION`; phar проверяется по GPG при каждой
сборке - передайте пустое значение, чтобы следовать последнему релизу).

Производный образ выполняет свои `RUN` от root и в конце возвращает
пользователя (hadolint отвергает нечисловой `USER`):

```dockerfile
FROM ghcr.io/6run0/freeunit-drupal:0.4.0-php8.4@sha256:...
USER 0:0
RUN apt-get update && apt-get install -y --no-install-recommends ...
USER 65532:65532
```

## Запуск

### Веб-роль

Основное применение: запуск сайта Drupal под веб-сервером FreeUnit.

```bash
# /tmp - каталог хоста во владении uid процесса; отсутствующий ./tmp Docker
# создаст root:root, и старт упадёт ("/tmp is not writable").
sudo install -d -o 65532 -g 65532 -m 0700 tmp
docker run -d --name drupal \
  -p 8080:8080 \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /run:size=16m,uid=65532,gid=65532,mode=0700 \
  -v "$PWD/tmp:/tmp" \
  -v "$PWD/web:/www:ro" \
  -v "$PWD/config.json:/docker-entrypoint.d/config.json:ro" \
  ghcr.io/6run0/freeunit-drupal:0.4.0-php8.4
```

При каждом запуске с пустым `/run` базовый entrypoint применяет всё
содержимое `/docker-entrypoint.d/` (скрипты, сертификаты, конфиг FreeUnit) и
запускает демон FreeUnit на переднем плане. Полное описание запуска и
соглашений `/docker-entrypoint.d/` смотрите в документации базового образа.

Минимальный `config.json` для Drupal:

```json
{
  "listeners": { "*:8080": { "pass": "applications/drupal" } },
  "applications": {
    "drupal": {
      "type": "php",
      "root": "/www",
      "script": "index.php"
    }
  }
}
```

Без ключей `user`/`group`: Unit без root запускает воркеры своим uid и
сменить пользователя не может.

### Cron-роль

Запустите тот же образ как cron-раннер на supercronic рядом с веб-контейнером
— без отдельного образа и без переопределения entrypoint.

```bash
docker run -d --name drupal-cron \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /run:size=16m,uid=65532,gid=65532,mode=0700 \
  -v "$PWD/tmp:/tmp" \
  -v "$PWD/crontab:/etc/supercronic/crontab:ro" \
  -e DRUPAL_CRON_URL=http://localhost:8080/cron/YOUR_CRON_KEY \
  ghcr.io/6run0/freeunit-drupal:0.4.0-php8.4 supercronic
```

Поставляемый crontab — это закомментированный шаблон без активных задач,
поэтому смонтируйте свой (как выше) или включите задачу в производном образе —
см. [Crontab по умолчанию](#crontab-по-умолчанию).

Передача `supercronic` как команды контейнера активирует cron-роль.
`dispatch_handler` базового entrypoint распознаёт её и вызывает
`handle_supercronic` из хука `/docker-entrypoint-hook.d/supercronic.sh`,
который:

1. Запускает операторские `*.sh` дроп-ины из `/docker-entrypoint.d/` (та же
   удобная возможность, что и в веб-роли).
2. `exec`-ит `supercronic` от пользователя контейнера (без сброса
   привилегий, без capabilities), пробрасывая любые аргументы, дописанные после
   команды `supercronic`, и подставляя путь к crontab по умолчанию, если он
   не передан (см. [Тонкая настройка supercronic](#тонкая-настройка-supercronic)).

#### Crontab по умолчанию

Образ поставляется с `/etc/supercronic/crontab` — **закомментированным
шаблоном без активных задач**: он документирует синтаксис расписаний и несёт
два закомментированных примера задач — Drush из проекта (предпочтительно,
см. совет ниже) и HTTP-триггер Drupal cron:

```cron
# */5 * * * * curl -fsS -o /dev/null "${DRUPAL_CRON_URL:-http://localhost:8080/cron.php}"
```

Поэтому cron-роль простаивает, пока вы не включите задачу: раскомментируйте
её в производном образе или смонтируйте собственный crontab по тому же пути:

```bash
-v "$PWD/crontab:/etc/supercronic/crontab:ro"
```

`DRUPAL_CRON_URL` должна содержать полный URL cron-эндпоинта Drupal,
включая cron-ключ (например,
`http://localhost:8080/cron/YOUR_CRON_KEY`).

> [!TIP]
> Если проект поставляет Drush, предпочитайте запускать cron через него, а
> не через HTTP-триггер: смонтируйте том с кодом в cron-контейнер и
> используйте строку crontab вида
> `*/15 * * * * /www/vendor/bin/drush --root=/www/web cron`. Drush выполняет
> cron в собственном CLI-процессе PHP: не нужно раскрывать cron-ключ, нет
> таймаута веб-запроса на долгих прогонах, и он продолжает работать, даже
> когда сайт в режиме обслуживания. HTTP-триггер остаётся вариантом без
> зависимостей, когда у cron-контейнера нет доступа к коду и базе.

supercronic также принимает расписания, недоступные POSIX cron: необязательное
ведущее поле **секунд** для субминутных задач (`*/30 * * * * *` = каждые
30 с), необязательное завершающее поле года, макросы
`@yearly`/`@monthly`/`@weekly`/`@daily`/`@hourly` и спецификаторы дней
`L`/`W`/`#`. Полный справочник — в комментариях шапки поставляемого crontab.

#### Тонкая настройка supercronic

Всё, что дописано после команды `supercronic`, пробрасывается напрямую раннеру,
поэтому его флаги не требуют пересборки образа:

```bash
# Перечитывать crontab при изменении (без перезапуска контейнера) и подробный лог
docker run -d --name drupal-cron \
  -v "$PWD/crontab:/etc/supercronic/crontab" \
  ghcr.io/6run0/freeunit-drupal:latest supercronic -inotify -debug
```

Если завершающий аргумент - существующий файл, он используется как crontab.
Если аргументов нет или завершающий - флаг, дописывается путь по умолчанию
(`/etc/supercronic/crontab`), так что добавление флага по-прежнему запускает
встроенный crontab. Любой другой завершающий аргумент (опечатка в пути или
значение флага, например `-prometheus-listen-address :9746`) останавливает
контейнер с `supercronic crontab not found: ...`; путь к crontab ставьте после
значения флага. Хук добавляет `-no-reap`, если вы его не передали: PID 1 -
tini, он и собирает осиротевшие процессы задач. Полный
список — `supercronic -help` (`-inotify`, `-overlapping`, `-split-logs`,
`-prometheus-listen-address`, …).

### Механизм хуков entrypoint

Cron-роль реализована как **хук entrypoint** — файл `*.sh` в
`/docker-entrypoint-hook.d/`, определяющий функцию `handle_supercronic`.
Базовый entrypoint подключает каждый хук перед диспетчингом, и когда команда
контейнера совпадает, обработчик берёт на себя запуск (он обязан `exec`-нуть
финальный процесс).

Дочерние образы **не переопределяют** `/docker-entrypoint.sh`, поэтому
каждый фикс надёжности и безопасности базового entrypoint наследуется
автоматически.

Правила написания хуков (соблюдение обеспечивает базовый диспетчер):

- Файл хука должен **только определять функции `handle_*`** — без
  побочных эффектов на верхнем уровне.
- Хук пишется на переносимом POSIX sh и подключается через `.` в `/bin/sh`
  образа (dash): конструкция bash - ошибка разбора, контейнер не стартует.
- `local` нет: каждая переменная и вспомогательная функция хука получает
  префикс `<cmd>_` (`supercronic_crontab`). `UNIT_*`, `ENTRYPOINT_*` и
  `_ep_*` заняты entrypoint.
- Обработчик вызывается слева от `||`, поэтому `set -e` внутри него не
  действует: значимые ошибки проверяйте явно.
- `handle_<cmd>` **обязан `exec`-нуть** финальный процесс. Возврат или
  выход с ненулевым кодом — фатальное нарушение контракта.
- Не затеняйте имена функций базовой библиотеки и переменные
  `UNIT_*` / `ENTRYPOINT_*`.
- Хук выполняется от пользователя контейнера. Диспетчер отвергает файл хука,
  который этот пользователь мог бы переписать (владелец не root или запись
  для группы/всех).

### Соглашения `/docker-entrypoint.d/`

Этот образ наследует обработку `/docker-entrypoint.d/` базового entrypoint
без изменений. Файлы применяются в лексическом порядке, по расширению:

| Расширение | Действие |
|------------|----------|
| `*.sh`     | Исполняется от пользователя контейнера. |
| `*.pem`    | Загружается как набор сертификатов с именем файла (без `.pem`). |
| `*.json`   | Отправляется `PUT`-запросом в `config` FreeUnit через управляющий сокет. |

Файлы прочих типов логируются и игнорируются. Скрипт, который рендерит
конфигурацию при старте, пишет её в `$ENTRYPOINT_GENERATED_DIR`
(`/run/docker-entrypoint.d`); его `*.pem` и `*.json` применяются после файлов
`/docker-entrypoint.d/`.

> Несколько `*.json` **не** объединяются: `PUT /config` заменяет всю
> конфигурацию, поэтому в силу вступает только лексически последний файл
> (entrypoint предупреждает, если их больше одного). Поставляйте один
> объединённый файл конфигурации.

В cron-роли `*.sh` дроп-ины выполняются, но `*.pem` и `*.json` не
обрабатываются (FreeUnit в этой роли не запускается).

### Почта (msmtp)

`mail()` PHP вызывает `/usr/sbin/sendmail`, который в этом образе симлинкован
на `msmtp`. Поставляемый `/etc/msmtprc` — **закомментированный шаблон без
активных настроек**: почта остаётся ненастроенной, пока вы не укажете свой
SMTP-релей — раскомментируйте и отредактируйте шаблон в дочернем образе или
смонтируйте собственный конфиг по тому же пути:

```bash
-v "$PWD/msmtprc:/etc/msmtprc:ro"
```

`/etc` пользователю контейнера недоступен для записи. Конфигурацию, которая
рендерится при старте, кладите в доступный для записи путь и называйте явно,
например `sendmail_path = "/usr/bin/msmtp -C /run/msmtprc -t -i"` в ini PHP
для `cli` и `embed` (задачи cron шлют почту через PHP CLI), или в
`~/.msmtprc`, если `HOME` доступен для записи.

Не храните учётные данные в этом общедоступном для чтения файле: шаблон
использует `passwordeval`, читающий пароль из смонтированного секрета
(например, `/run/secrets/smtp_password`) вместо строки `password` открытым
текстом.

## Переменные окружения

Переменные, унаследованные от базового образа (`UNIT_ENTRYPOINT_QUIET_LOGS`),
описаны в
[README freeunit-php](https://github.com/6RUN0/docker-freeunit-php#environment-variables).
Этот образ добавляет одну собственную переменную:

| Переменная | По умолчанию | Назначение |
|------------|--------------|------------|
| `DRUPAL_CRON_URL` | _не задана_ | URL cron-эндпоинта Drupal (включая cron-ключ), используемый crontab по умолчанию. При отсутствии используется `http://localhost:8080/cron.php`. |

## Запуск без root

Обе роли работают от пользователя образа `nonroot` (65532:65532) с первой
инструкции: tini, entrypoint, мастер и PHP-воркеры FreeUnit, supercronic и его
задачи. Capabilities не нужны; запуск:

```bash
sudo install -d -o 65532 -g 65532 -m 0700 tmp   # один раз: bind mount /tmp должен принадлежать uid
docker run --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /run:size=16m,uid=65532,gid=65532,mode=0700 \
  -v "$PWD/tmp:/tmp" \
  ...
```

| Путь | Запись нужна | Что там |
|------|--------------|---------|
| `/run` | да (маленький tmpfs) | управляющий сокет Unit, pid, состояние (`/run/freeunit`), сгенерированная конфигурация |
| `/tmp` | да (bind mount на диск) | тела запросов до `max_body_size`, загрузки и временные файлы PHP, сессии, временные файлы задач |
| `HOME` (`/home/nonroot`) | нет | `composer install` и Drush работают с `HOME` только для чтения (см. ниже) |
| ваши bind mount | по нуждам приложения | должны быть доступны для записи uid процесса (`chown` при старте нет) |

- С `HOME` только для чтения у Composer нет глобального конфига
  (`composer config -g` падает) и кеша, git не может записать `~/.gitconfig`
  (`git config --global`, например `safe.directory`), ssh не запишет
  `known_hosts`. При нужде направьте `COMPOSER_HOME` / `COMPOSER_CACHE_DIR` в
  доступный для записи путь; настройки git передавайте через
  `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>` или
  `/etc/gitconfig` в производном образе.
- Подходит любой не-root uid:gid (`--user` / `user:` в compose); tmpfs
  получает те же `uid=`/`gid=`. ssh (git по SSH) нужна запись passwd для
  uid: у 65532 она есть, другому uid нужна своя в производном образе.
- Слушателю на порту ниже 1024 нужен `net.ipv4.ip_unprivileged_port_start=0`
  (умолчание Docker; явно - через `--sysctl`).
- Запуск от root (`--user 0:0`) сбрасывается на 65532, если у контейнера есть
  `CAP_SETUID`, `CAP_SETGID`, `CAP_CHOWN` и `CAP_KILL` (tini остаётся root и
  пересылает `docker stop` процессам 65532), иначе отвергается. Это запасной
  режим, не рекомендуемый.
- Control API, каталог состояния и каталог сгенерированной конфигурации
  принадлежат тому же uid, что PHP-воркеры: выполнение кода в PHP может
  перенастроить Unit до перезапуска контейнера. Unix-сокет закрывает SSRF, но
  не RCE.
- `docker exec` идёт от пользователя контейнера; `docker exec -u 0` обходит
  всё перечисленное. Используйте его только для чтения.

Подробности - в [README freeunit-php](https://github.com/6RUN0/docker-freeunit-php/blob/main/README.ru.md#запуск-без-root).

Относитесь к `/docker-entrypoint.d/*.sh` как к доверенному вводу: эти скрипты
выполняются в оболочке entrypoint до старта FreeUnit.

## См. также

- [Список изменений](CHANGELOG.ru.md)
- [Базовый образ freeunit-php](https://github.com/6RUN0/docker-freeunit-php)
- [FreeUnit (апстрим)](https://github.com/freeunitorg/freeunit)
- [supercronic](https://github.com/aptible/supercronic)
- [Unit в Docker на unit.nginx.org](https://unit.nginx.org/howto/docker/)
