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
  (SMTP-клиент за `mail()` PHP, см. [Почта](#почта-msmtp)), `patch` (чтобы `cweagans/composer-patches` мог
  накладывать патчи с drupal.org во время `composer install`) и `unzip`
  (распаковка архивов пакетов Composer).

Код приложения Drupal **не** запекается в образ. Он монтируется или
устанавливается Composer'ом в рантайме. Этот образ — среда выполнения,
а не сайт.

Зато в нём есть общая стартовая обвязка Drupal-сайта, каждая часть включается
явно: рендер конфигурации Unit с маршрутами Drupal, рендер `/run/msmtprc`,
проверка каталогов для записи, `drush cr`/`updb`/`cr` на старте, healthcheck,
чистка `/tmp`, фрагмент усиления compose и его проверка (см.
[Скрипты Drupal в entrypoint](#скрипты-drupal-в-entrypoint) и
[Стабильность](#стабильность)).

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
запускает демон FreeUnit на переднем плане. Собственные скрипты образа там
без своих переменных ничего не делают; монтируйте в `/docker-entrypoint.d/`
отдельные файлы, как выше: каталог, смонтированный поверх, прячет их (см.
[Скрипты Drupal в entrypoint](#скрипты-drupal-в-entrypoint)). Полное
описание запуска и соглашений `/docker-entrypoint.d/` смотрите в документации
базового образа.

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

`mail()` PHP запускает `sendmail_path`. Образ задаёт его для `cli` и `embed`
(`/etc/php/<X.Y>/{cli,embed}/conf.d/05-freeunit-drupal-sendmail.ini`) равным
`/usr/local/bin/freeunit-drupal-sendmail -t -i`, и `/usr/sbin/sendmail`
ссылается на ту же обёртку. Обёртка запускает `msmtp -C /run/msmtprc`, если
`/run/msmtprc` существует, иначе просто `msmtp` (он читает `/etc/msmtprc`).

Её вызывает код PHP, поэтому она принимает только параметры, которые передают
`mail()` PHP, `PhpMail` Drupal (`-f<адрес>`) и sendmail-транспорт Symfony
(`-f<адрес>`, `-i`, `--`): `-t`, `-i`, `-oi`, `-f <адрес>` или `-f<адрес>`,
`-F <имя>` или `-F<имя>`, `--`, получателей и диагностические `--pretend` и
`--version`, каждый отдельным аргументом. Всё остальное, в том числе
склеенные `-ti` и `-tC/x` и сокращённый `--fil=`, - код 64 (`EX_USAGE`) до
запуска msmtp.

`sendmail://default` в Symfony mailer по умолчанию запускает
`/usr/sbin/sendmail -bs`: режима `-bs` у msmtp нет, и обёртка отвергает его с
кодом 64. Задайте транспорту форму с `-t`, например
`sendmail://default?command=/usr/sbin/sendmail%20-t%20-i`.

msmtp не держит очереди: его код 75 (`EX_TEMPFAIL`, релей не разрешается или
отказывает) значит, что письмо потеряно, а `mail()` PHP 8.5 сочла бы его
отправленным. Обёртка переводит 75 в 69 (`EX_UNAVAILABLE`), поэтому `mail()`
возвращает `false` на всех ветках PHP; остальные коды проходят как есть.

Почта настраивается одним из трёх способов:

- задать `FREEUNIT_DRUPAL_SMTP_HOST` и `FREEUNIT_DRUPAL_SMTP_FROM`: образ
  пишет `/run/msmtprc` при старте (см.
  [Скрипты Drupal в entrypoint](#скрипты-drupal-в-entrypoint));
- рендерить `/run/msmtprc` своим скриптом, как до 0.5.0: обёртка возьмёт его,
  `FREEUNIT_DRUPAL_SMTP_HOST` при этом не задаётся;
- смонтировать или встроить файл в `/etc/msmtprc`; в образе это
  **закомментированный шаблон без активных настроек**:

```bash
-v "$PWD/msmtprc:/etc/msmtprc:ro"
```

`sendmail_path` из ini сайта, который сортируется после `05-` (например
`95-site.ini` в обоих `conf.d`), перекрывает значение образа. `sendmail_path` в
главном `php.ini` производного образа не перекрывает: `conf.d` читается после
него.

Не храните учётные данные в общедоступном для чтения `/etc/msmtprc`: шаблон
использует `passwordeval`, читающий пароль из смонтированного секрета
(например, `/run/secrets/smtp_password`) вместо строки `password` открытым
текстом.

## Скрипты Drupal в entrypoint

Образ поставляет стартовую обвязку Drupal-сайта: четыре скрипта в
`/docker-entrypoint.d/` и библиотеку. Каждый **включается явно**: без своей
переменной скрипт ничего не пишет и не меняет, поэтому обновление образа не
меняет сайт, который ни одну из них не задаёт.

| Скрипт | Включается | Делает |
|--------|------------|--------|
| `10-freeunit-drupal-writable-dirs.sh` | `FREEUNIT_DRUPAL_WRITABLE_DIRS` | останавливает старт, если хоть один каталог из списка недоступен для записи uid процесса; всегда предупреждает о незнакомом имени `FREEUNIT_DRUPAL_*` |
| `20-freeunit-drupal-msmtp.sh` | `FREEUNIT_DRUPAL_SMTP_HOST` | пишет `/run/msmtprc` (0600) |
| `30-freeunit-drupal-unit-config.sh` | `FREEUNIT_DRUPAL_UNIT_CONFIG=1` | рендерит конфигурацию Unit в `$ENTRYPOINT_GENERATED_DIR/freeunit-drupal.json` |
| `90-freeunit-drupal-upgrade.sh` | `FREEUNIT_DRUPAL_UPGRADE=1` | ждёт базу данных, затем на установленном сайте `drush cr`, `updb --yes`, `cr` |

Когда они выполняются:

- веб-роль: внутри раунда начальной конфигурации базового entrypoint, который
  идёт на каждом старте с пустым `/run/freeunit` (tmpfs `/run` пуст на каждом
  старте), при временном демоне Unit на control socket;
- cron-роль (`supercronic`): на каждом старте, до supercronic;
- любая другая команда (`docker run <образ> drush ...`): никогда.

Упавший скрипт останавливает старт; базовый entrypoint после сообщения
скрипта пишет `entrypoint script failed (exit N): /docker-entrypoint.d/<файл>`.

### Порядок и скрипты сайта

База выполняет `/docker-entrypoint.d/*.sh` в байтовом порядке (`LC_ALL=C`).
`-` сортируется раньше цифр, поэтому скрипт сайта с трёхзначным номером и `_`
встаёт рядом с двузначными скриптами образа:

| Скрипт сайта | Выполняется |
|--------------|-------------|
| `000_` - `099_` | до `10-` |
| `100_` - `199_` | между `10-` и `20-` |
| `200_` - `299_` | между `20-` и `30-` |
| `300_` - `899_` | между `30-` и `90-` |
| `900_` - `999_` | после `90-` |

Например, `000_configure.sh` - раньше всех, `500_install.sh` - между
конфигурацией Unit и обновлением, `999_finish.sh` - последним. Скрипт сайта
копируется в производный образ с битом исполнения (`COPY --chmod=0755 ...`).

- Выключить скрипт: не задавать его переменную.
- Заменить: не задавать переменную и положить свой скрипт в нужный слот.
- Удалить: `RUN rm /docker-entrypoint.d/<файл>` в производном образе (под
  `USER 0:0`); имена файлов входят в [Стабильность](#стабильность).
- Каталог, смонтированный поверх `/docker-entrypoint.d` (пример
  [веб-роли](#веб-роль) монтирует один файл, а не каталог), прячет скрипты
  образа: ни один не выполняется, какие бы переменные ни были заданы. Почта
  по-прежнему идёт через обёртку, а затем в `/etc/msmtprc`.

Скрипт сайта может подключить библиотеку и пользоваться её публичными
функциями:

```sh
#!/bin/sh
set -eu
. /usr/local/lib/freeunit-drupal/lib.sh
freeunit_drupal_wait_for_db 120
freeunit_drupal_drush status --field=bootstrap
```

| Функция | Делает |
|---------|--------|
| `freeunit_drupal_log_info`, `_log_notice`, `_log_warn` `<сообщение>` | строка лога entrypoint в stderr с префиксом `freeunit-drupal:` |
| `freeunit_drupal_die <сообщение>` | строка ошибки, затем `exit 1` |
| `freeunit_drupal_flag_enabled <ИМЯ>` | истина для `1`, ложь для не заданной, пустой или `0`, на любом другом значении останавливает |
| `freeunit_drupal_drush <аргументы>` | `$FREEUNIT_DRUPAL_PROJECT_DIR/vendor/bin/drush --root=$FREEUNIT_DRUPAL_DOCROOT --no-interaction <аргументы>`; останавливает, если drush нет |
| `freeunit_drupal_wait_for_db [секунды]` | `drush sql:query 'SELECT 1'` раз в 2 с, не дольше `секунды` (по умолчанию `FREEUNIT_DRUPAL_UPGRADE_DB_WAIT`, иначе 60), каждая попытка под `timeout` с оставшимся временем; затем останавливает с последней строкой stderr drush |

Библиотека подключает базовую библиотеку `/docker-entrypoint-common.sh`; её
функции и все имена `_fd_*` - детали реализации.

### Переменные

Все имена начинаются с `FREEUNIT_DRUPAL_`; префиксы `FREEUNIT_DRUPAL_`,
`freeunit_drupal_` и `_fd_` зарезервированы за образом, рядом с `UNIT_*`,
`ENTRYPOINT_*` и `_ep_*` базы. Флаг (`_UNIT_CONFIG`, `_UPGRADE`) принимает
только "не задан", пусто, `0` (выключен) или `1` (включён); любое другое
значение, в том числе `yes` и `true`, останавливает старт. `_SMTP_TLS` и
`_SMTP_AUTH` принимают только `on` и `off`.

| Переменная (`FREEUNIT_DRUPAL_` +) | По умолчанию | Назначение |
|-----------------------------------|--------------|------------|
| `PROJECT_DIR` | `/www` | корень проекта Composer (`vendor/bin/drush`) |
| `DOCROOT` | `$FREEUNIT_DRUPAL_PROJECT_DIR/web` | docroot Drupal: `root` и `share` Unit, `--root` drush |
| `WRITABLE_DIRS` | не задана | каталоги, обязанные быть доступными для записи, через пробельные символы; относительный путь берётся от `PROJECT_DIR` |
| `UNIT_CONFIG` | не задана | `1` рендерит конфигурацию Unit |
| `UNIT_TEMPLATE` | `/usr/local/share/freeunit-drupal/unit.json.template` | шаблон Unit для рендера |
| `UNIT_LISTEN` | `*:8080` | слушатель встроенного шаблона |
| `UNIT_MAX_BODY_SIZE` | `33554432` | `settings.http.max_body_size`, байты; на запрос больше Unit отвечает 413 |
| `UNIT_PROCESSES_MAX` / `_SPARE` / `UNIT_PROCESS_IDLE_TIMEOUT` | `8` / `2` / `30` | `processes` приложения |
| `UNIT_LIMITS_TIMEOUT` / `UNIT_LIMITS_REQUESTS` | `60` / `1000` | `limits` приложения |
| `PHP_MEMORY_LIMIT` | `256M` | `memory_limit` |
| `PHP_MAX_EXECUTION_TIME` | `60` | `max_execution_time` |
| `PHP_POST_MAX_SIZE` / `PHP_UPLOAD_MAX_FILESIZE` | `32M` / `32M` | `post_max_size` / `upload_max_filesize` |
| `PHP_TIMEZONE` | `UTC` | `date.timezone` |
| `SMTP_HOST` | не задана | SMTP-релей; заданная, включает `20-` |
| `SMTP_PORT` | `25` | порт SMTP |
| `SMTP_FROM` | не задана, обязательна при `SMTP_HOST` | отправитель конверта |
| `SMTP_TLS` | `off` | `on`: TLS с системным хранилищем CA |
| `SMTP_AUTH` | `off` | `on`: требует `SMTP_TLS=on`, `SMTP_USER`, `SMTP_PASSWORD_FILE` |
| `SMTP_USER` | не задана | пользователь SMTP |
| `SMTP_PASSWORD_FILE` | не задана | абсолютный путь читаемого файла с паролем, без `'`; msmtp читает его при отправке |
| `MSMTP_TEMPLATE` | не задана | свой шаблон msmtp вместо встроенной учётной записи |
| `UPGRADE` | не задана | `1` включает `90-` |
| `UPGRADE_DB_WAIT` | `60` | секунды ожидания базы данных |
| `HEALTHCHECK_HOST` | не задана, обязательна | `Host` для `freeunit-drupal-healthcheck` |
| `HEALTHCHECK_PORT` / `_PATH` / `_PROTO` / `_TIMEOUT` | `8080` / `/` / `https` / `20` | порт, путь, `X-Forwarded-Proto`, секунды `curl --max-time` |
| `RUN_UID` / `RUN_GID` / `TMP_DIR` | `65532` / `65532` / обязательна | интерполяция фрагмента усиления |
| `HARDENING_ENV_FILE` / `_HOST` / `_WRITABLE_DIRS` / `_CRONTAB` | см. [Проверка усиления](#проверка-усиления) | параметры проверки усиления |

URI сайта для drush - переменная drush `DRUSH_OPTIONS_URI`.

Переменной для `apc.shm_size` нет: APCu выделяет сегмент при старте модуля
PHP, до того как Unit применяет `options.admin`, поэтому `ini_get()` показал
бы значение, а сегмент остался бы прежним. Задавайте его в ini производного
образа (`/etc/php/<X.Y>/embed/conf.d/`).

### Конфигурация Unit

`30-` рендерит шаблон в `$ENTRYPOINT_GENERATED_DIR/freeunit-drupal.json`, база
применяет его после скриптов. `PUT /config` заменяет конфигурацию целиком,
поэтому другой `*.json` в `/docker-entrypoint.d` или в generated dir
останавливает старт (`... was written by an earlier script; drop it or unset
FREEUNIT_DRUPAL_UNIT_CONFIG`); файл, записанный `30-` на прошлом старте, не
считается.

Встроенный шаблон отдаёт `FREEUNIT_DRUPAL_DOCROOT` на `UNIT_LISTEN` с одним
PHP-приложением (`index.php`) и такими маршрутами по порядку:

1. 404 для исходников и служебных файлов: `*.json`, `*.yml`, `*.lock`, `*.md`,
   `*.twig`, `*.txt`, `*.sh`, расширение, оканчивающееся на `sql` (`.sql`,
   `.mysql`, `.pgsql`; путь вроде `/tags/postgresql` им не является), `*/.*`,
   `/composer.*`, `/vendor/*`, `/core/scripts/*`, `/core/tests/*` и остальной
   список шаблона. Кроме `/robots.txt`, `/.well-known/*` (ACME,
   `security.txt`) и публичного каталога файлов `/sites/<сайт>/files/`, где
   загрузки сохраняют любое расширение (`.txt`, `.csv`, `.json`);
2. 404 под `/sites/<сайт>/files/` для скрытого имени (`.htaccess`), для всего
   поддерева `config_*/` (туда установщик Drupal кладёт каталог синхронизации
   конфигурации, если `config_sync_directory` не задан) и для расширений,
   которые запрещает `.htaccess` Drupal и которые не бывают законной
   загрузкой: `.yml`, `.sql` (и `*sql`), `.inc`, `.install`, `.module`,
   `.profile`, `.engine`, `.theme`, `.twig`, `.tpl`, `.xtmpl`, `.make`, `.po`,
   `.sh`, а также суффиксов копий `~`, `.swp`, `.swo`, `.bak`, `.orig`, `.save`;
3. 404 для `/core/install.php`, `/core/authorize.php`, `/core/rebuild.php` и
   `/update.php`: при `settings.php` только для чтения установщик пошёл бы в
   боевую базу; обновления - через `drush updb` (`90-`). Сайту, которому
   нужен `update.php` по HTTP, - свой шаблон;
4. 404 для любого другого `*.php`, кроме `/index.php`, поэтому PHP из
   `sites/default/files` не исполняется никогда;
5. `/index.php` - приложению;
6. статический файл docroot, если он есть, иначе приложение.

Лог доступа идёт в `/dev/stdout`. Цели `direct` для других PHP-скриптов нет.

Рендер (и `30-`, и `MSMTP_TEMPLATE`): каждый `%%ИМЯ%%`, где `ИМЯ` - переменная
окружения, заменяется её значением за один проход; значение повторно не
разбирается. Рендер останавливает старт, если `ИМЯ` не определено
(определённое пустое подставляется пустым), если в значении перевод строки и,
для JSON-шаблона, если в значении `"`, `\` или управляющий символ либо
результат не разбирается как JSON. Умолчания из таблицы выше выставляются до
рендера; значение из окружения важнее. Значения попадают в generated dir и в
конфигурацию Unit, читаемые uid процесса PHP: секреты передаются файлами,
никогда через шаблон.

### Конфигурация почты

`20-` требует `SMTP_FROM` и пишет `/run/msmtprc`, 0600, первая строка
`# freeunit-drupal`, из `MSMTP_TEMPLATE` или из встроенной учётной записи
(`host`, `port`, `from`, `tls`, `auth`, `logfile -`). При `SMTP_AUTH=on` в
файле стоит `passwordeval "cat '<SMTP_PASSWORD_FILE>'"`, а не пароль. Для
неявного TLS на порту 465 (`tls_starttls off`) - `MSMTP_TEMPLATE`.

`/run/msmtprc` без этой первой строки записан более ранним скриптом и
останавливает старт (`... unset FREEUNIT_DRUPAL_SMTP_HOST or drop that
script`); файл с ней остался от прошлого старта на том же `/run` и
перезаписывается.

`logfile -` пишет каждую доставку, включая адреса получателей, в лог
контейнера: это персональные данные, срок их хранения решает сайт.

### Обновление

`90-` при `FREEUNIT_DRUPAL_UPGRADE=1`:

1. в веб-роли предупреждает `upgrade runs in the web role; enable it in one role
   only` и продолжает; включайте его только в cron-роли, иначе `updb`
   выполнят обе роли;
2. `freeunit_drupal_wait_for_db`; по истечении старт останавливается с
   `database not reachable after N s: <последняя строка stderr drush>`, где
   видна причина (отказ в соединении, исключение `settings.php`);
3. `drush status --field=bootstrap` не `Successful`: notice
   `Drupal not installed, skipping upgrade`, старт продолжается;
4. `drush cr`, `drush updb --yes`, `drush cr`; упавший шаг останавливает старт
   со своим именем.

Обновление локалей сюда не входит.

### Healthcheck и чистка /tmp

`freeunit-drupal-healthcheck` - healthcheck веб-роли сайта:

```yaml
healthcheck:
  test: ["CMD", "freeunit-drupal-healthcheck"]
```

Он шлёт `GET http://127.0.0.1:$PORT$PATH` с `Host: $HOST`,
`X-Forwarded-For: 127.0.0.1`, `X-Forwarded-Host`, `X-Forwarded-Proto` и
соответствующим `X-Forwarded-Port` (443 или 80), `curl --max-time $TIMEOUT`,
без перехода по редиректам: 2xx и 3xx - здоров (неустановленный сайт отвечает
302), всё остальное и таймаут - код 1. Без `HEALTHCHECK_HOST` - код 1 с
именем переменной. Пока идёт раунд конфигурации (слушателя приложения ещё
нет), он не проходит, в том числе когда раунд держит ожидание базы `90-` в
веб-роли.

`HEALTHCHECK` образа - базовый и не меняется: он спрашивает control socket
Unit, на который отвечает и временный демон раунда, поэтому сообщает
"здоров" раньше, чем появляется слушатель. Сайт берёт
`freeunit-drupal-healthcheck` для healthcheck в compose и
`depends_on: condition: service_healthy`.

`freeunit-drupal-tmp-cleanup [дни]` (по умолчанию 1) удаляет файлы `/tmp`
старше `дни`, затем пустые каталоги того же возраста (`find -mtime +N`: не
меньше `(N+1) * 24` часов), не выходя за файловую систему `/tmp` и не трогая
симлинки; нечисловой аргумент - код 64. Под фрагментом усиления `/tmp` -
bind mount на диске, который больше никто не чистит: добавьте строку в
crontab, например `30 3 * * * freeunit-drupal-tmp-cleanup 1`.

### Фрагмент усиления

`/usr/local/share/freeunit-drupal/docker-compose.hardening.yml` задаёт сервис
`hardened`: `user` `${FREEUNIT_DRUPAL_RUN_UID:-65532}:${FREEUNIT_DRUPAL_RUN_GID:-65532}`,
`read_only`, `no-new-privileges`, `cap_drop: [ALL]`, sysctl
`net.ipv4.ip_unprivileged_port_start: 0`, tmpfs `/run` на 16 МБ этого uid и
`${FREEUNIT_DRUPAL_TMP_DIR}`, смонтированный в `/tmp` (compose останавливается,
если переменная не задана). Сайт держит копию рядом со своим compose-файлом и
расширяет её:

```yaml
services:
  unit:
    extends:
      file: docker-compose.hardening.yml
      service: hardened
```

`sysctls` не работает при `network_mode: host`. Относительный
`FREEUNIT_DRUPAL_TMP_DIR` разрешается от каталога копии фрагмента; каталог
должен принадлежать uid запуска.

### Проверка усиления

`/usr/local/share/freeunit-drupal/test/hardening-check.sh` запускает образ
сайта как unit и cron под фрагментом, без базы данных, в своём проекте
compose `freeunit-drupal-hardening-<pid>` (удаляется при выходе) и печатает
TAP: старт и здоровье, слушатель Unit, статический файл
(`/core/misc/drupal.js`), ответ PHP на `GET` и `POST` в 1 МБ, `/run/msmtprc`,
если сайт задаёт `FREEUNIT_DRUPAL_SMTP_HOST`, `sendmail_path` cli и embed,
рестарт, первую задачу cron, uid каждого процесса, отсутствие ошибок записи и
прав в логах, отказ старта от root и старта с `/tmp`, недоступным uid для
записи. Код 0: все тесты прошли; 1: тест провален; 2: не выполнено
предусловие (`Bail out!`).

Чего она не видит: `sendmail_path` для embed читается из ini-файлов, поэтому
значение из шаблона Unit сайта (`options.admin`) или через `PHP_INI_SCAN_DIR`
пропускается; здоровье - это `HEALTHCHECK` образа (control socket), а не
`freeunit-drupal-healthcheck`, потому что базы нет; `/tmp` - том проекта
проверки, поэтому `FREEUNIT_DRUPAL_TMP_DIR` чужого владельца на хосте сайта не
обнаруживается (обнаруживается только `/tmp`, недоступный uid для записи, как
отказ старта).

```sh
hardening-check.sh [--compose-copy <файл>] <образ>
```

| Параметр | По умолчанию | Смысл |
|----------|--------------|-------|
| `--compose-copy <файл>` | не проверяется | копия сайта должна совпадать с фрагментом `<образа>` байт в байт |
| `FREEUNIT_DRUPAL_HARDENING_ENV_FILE` | нет | env-файл сайта для обеих ролей, после умолчаний `FREEUNIT_DRUPAL_UNIT_CONFIG=1` и `FREEUNIT_DRUPAL_HEALTHCHECK_HOST` |
| `FREEUNIT_DRUPAL_HARDENING_HOST` | `localhost` | `Host` запросов |
| `FREEUNIT_DRUPAL_HARDENING_WRITABLE_DIRS` | нет | каталоги контейнера, монтируемые как tmpfs uid запуска |
| `FREEUNIT_DRUPAL_HARDENING_CRONTAB` | нет | crontab cron-роли; заданный, проверка ждёт до 75 с окончания первой задачи |

Скрипт выполняется на хосте с правами docker socket. Берите его из
проверенного образа, по digest, а не из ветки:

```sh
digest=sha256:...   # digest, который закрепляет ваш сайт
gh attestation verify "oci://ghcr.io/6run0/freeunit-drupal@$digest" --owner 6RUN0
docker run --rm --entrypoint cat "ghcr.io/6run0/freeunit-drupal@$digest" \
  /usr/local/share/freeunit-drupal/test/hardening-check.sh > hardening-check.sh
sh hardening-check.sh --compose-copy docker-compose.hardening.yml <образ сайта>
```

### Принятые риски

- Control socket, generated dir и `/run/msmtprc` принадлежат uid PHP-воркеров:
  выполнение кода в PHP может перенастроить Unit и почтовый релей до
  перезапуска контейнера. Unix socket закрывает SSRF, но не RCE. Поэтому
  обёртка доверяет `/run/msmtprc` по факту существования: его пишет тот же uid.
- Значения, подставленные в конфигурацию Unit, этот uid читает через control
  socket.
- `logfile -` пишет адреса получателей в лог контейнера.

## Стартовый пример

[`examples/drupal`](examples/drupal/) - заготовка нового сайта и сквозной
тест образа: `drupal/recommended-project`, собранный в образ сайта `FROM
ghcr.io/6run0/freeunit-drupal:<version>-php8.4`, unit и cron под копией
фрагмента усиления, Varnish с BAN по cache tags на неопубликованном
слушателе, MariaDB, Redis с паролем и под профилем compose `search` -
OpenSearch; секреты - файлы, сервисы данных - во внутренней сети. Сайт
копирует каталог и дальше владеет копией.

```sh
make test-example                     # собирает PHP по умолчанию, затем e2e-тест (TAP)
make test-example E2E_ARGS=--search   # с OpenSearch
```

Тест подменяет тег `FROM` локальным образом, поэтому идёт на `develop` до
появления тега. CI запускает его на каждый push и pull request, с профилем
search - раз в неделю; `release.yml` не публикует образ, пока тест падает.

## Переменные окружения

Переменные, унаследованные от базового образа (`UNIT_ENTRYPOINT_QUIET_LOGS`),
описаны в
[README freeunit-php](https://github.com/6RUN0/docker-freeunit-php#environment-variables).
Переменные `FREEUNIT_DRUPAL_*` скриптов Drupal перечислены в разделе
[Переменные](#переменные). Crontab по умолчанию читает ещё одну:

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
  принадлежат тому же uid, что PHP-воркеры (см.
  [Принятые риски](#принятые-риски)).
- `docker exec` идёт от пользователя контейнера; `docker exec -u 0` обходит
  всё перечисленное. Используйте его только для чтения.

Подробности - в [README freeunit-php](https://github.com/6RUN0/docker-freeunit-php/blob/main/README.ru.md#запуск-без-root).

Относитесь к `/docker-entrypoint.d/*.sh` как к доверенному вводу: эти скрипты
выполняются в оболочке entrypoint до старта FreeUnit.

## Стабильность

С 0.5.0 пункты ниже - публичный контракт образа. Изменение любого из них -
ломающее изменение: запись `Changed` в списке изменений и новая минорная
версия (0.x).

1. Переменные из раздела [Переменные](#переменные), их допустимые значения и
   умолчания, включая значения флагов ("не задан", пусто, `0`, `1`),
   интерполяцию `FREEUNIT_DRUPAL_RUN_UID`, `_RUN_GID`, `_TMP_DIR` во фрагменте
   и параметры `FREEUNIT_DRUPAL_HARDENING_*`. Префиксы `FREEUNIT_DRUPAL_`,
   `freeunit_drupal_` и `_fd_` зарезервированы.
2. Имена скриптов `/docker-entrypoint.d/10-freeunit-drupal-writable-dirs.sh`,
   `20-freeunit-drupal-msmtp.sh`, `30-freeunit-drupal-unit-config.sh`,
   `90-freeunit-drupal-upgrade.sh`; правило слотов из
   [Порядок и скрипты сайта](#порядок-и-скрипты-сайта); инвариант "скрипт
   образа без своей переменной ничего не пишет и не меняет", поэтому новый
   скрипт `NN-freeunit-drupal-*` в следующем выпуске не сдвигает скрипты
   сайта.
3. Пути `/usr/local/bin/freeunit-drupal-sendmail`,
   `/usr/local/bin/freeunit-drupal-healthcheck`,
   `/usr/local/bin/freeunit-drupal-tmp-cleanup`; ini
   `05-freeunit-drupal-sendmail.ini` в `cli` и `embed`; `/usr/sbin/sendmail`
   как обёртка; `/run/msmtprc` и его первая строка `# freeunit-drupal`;
   `$ENTRYPOINT_GENERATED_DIR/freeunit-drupal.json`;
   `/usr/local/share/freeunit-drupal/unit.json.template`, умолчания и маршруты
   встроенного шаблона;
   `/usr/local/share/freeunit-drupal/docker-compose.hardening.yml` с сервисом
   `hardened`; `/usr/local/share/freeunit-drupal/test/hardening-check.sh` и его
   аргументы.
4. `/usr/local/lib/freeunit-drupal/lib.sh` и только эти функции:
   `freeunit_drupal_log_info`, `freeunit_drupal_log_notice`,
   `freeunit_drupal_log_warn`, `freeunit_drupal_die`,
   `freeunit_drupal_flag_enabled`, `freeunit_drupal_drush`,
   `freeunit_drupal_wait_for_db`.

Не входят в контракт: функции и переменные базовой библиотеки, которыми
`lib.sh` пользуется внутри, имена `_fd_*`, текст сообщений лога и содержимое
`examples/drupal` (сайт копирует его и дальше владеет копией).

## См. также

- [Список изменений](CHANGELOG.ru.md)
- [Базовый образ freeunit-php](https://github.com/6RUN0/docker-freeunit-php)
- [FreeUnit (апстрим)](https://github.com/freeunitorg/freeunit)
- [supercronic](https://github.com/aptible/supercronic)
- [Unit в Docker на unit.nginx.org](https://unit.nginx.org/howto/docker/)
