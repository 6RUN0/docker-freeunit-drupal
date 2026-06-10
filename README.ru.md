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

- **Базовый образ:** `ghcr.io/6run0/freeunit-php` (trixie, amd64)
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
| `<версия>` | `:0.2.0` | этот релиз репозитория, PHP по умолчанию |
| `<base-tag>-php<X.Y>` | `:trixie-php8.4` | свежий релиз на ветке PHP (двигается вперёд) |
| `<версия>-php<X.Y>` | `:0.2.0-php8.4` | конкретный релиз на ветке PHP |

```bash
docker pull ghcr.io/6run0/freeunit-drupal:trixie-php8.4
```

Теги `latest` и `<base-tag>-php<X.Y>` плавающие. Теги `<версия>…`
привязаны к одному релизу. Подложка (`freeunit-php`) закрепляется через
`BASE_TAG` — см. раздел «Сборка».

## Сборка

```bash
# Образ по умолчанию (trixie, php8.4)
docker build -t freeunit-drupal .

# Конкретная версия PHP
docker build --build-arg PHP_VER=8.3 -t freeunit-drupal:8.3 .

# Закрепить подложку freeunit-php на конкретном релизе
docker build --build-arg BASE_TAG=trixie-1.35.5-build4 -t freeunit-drupal .
```

Или через Makefile:

```bash
make                                        # собрать все версии PHP (8.3, 8.4, 8.5)
make php8.3                                 # собрать один вариант
make latest                                 # собрать PHP по умолчанию (8.4) и пометить :latest
make test                                   # собрать PHP по умолчанию и прогнать smoke-тест
make lint                                   # запустить все установленные линтеры
make scan                                   # CVE-сканирование образа по умолчанию
make BASE_TAG=trixie-1.35.5-build4 php8.4  # закрепить подложку
```

Значения по умолчанию (`BASE_IMAGE`, `BASE_TAG`, `PHP_VER`) хранятся в ARG-ах
`Dockerfile`. `Makefile` читает их оттуда, поэтому обновление подложки — это
одна правка в `Dockerfile`. Единственный ассет, закреплённый в этом репо,
— `supercronic` (версия + SHA256 в ARG-ах `Dockerfile`).

## Запуск

### Веб-роль

Основное применение: запуск сайта Drupal под веб-сервером FreeUnit.

```bash
docker run -d --name drupal \
  -p 8080:8080 \
  -v "$PWD/web:/www:ro" \
  -v "$PWD/config.json:/docker-entrypoint.d/config.json:ro" \
  ghcr.io/6run0/freeunit-drupal:trixie-php8.4
```

При первом запуске базовый entrypoint применяет всё содержимое
`/docker-entrypoint.d/` (скрипты, сертификаты, конфиг Unit) и запускает
демон Unit на переднем плане. Полное описание первого запуска и соглашений
`/docker-entrypoint.d/` смотрите в документации базового образа.

Минимальный `config.json` для Drupal:

```json
{
  "listeners": { "*:8080": { "pass": "applications/drupal" } },
  "applications": {
    "drupal": {
      "type": "php",
      "root": "/www",
      "script": "index.php",
      "user": "unit",
      "group": "unit"
    }
  }
}
```

### Cron-роль

Запустите тот же образ как cron-раннер на supercronic рядом с веб-контейнером
— без отдельного образа и без переопределения entrypoint.

```bash
docker run -d --name drupal-cron \
  -v "$PWD/crontab:/etc/supercronic/crontab:ro" \
  -e DRUPAL_CRON_URL=http://localhost:8080/cron.php?cron_key=YOUR_KEY \
  ghcr.io/6run0/freeunit-drupal:trixie-php8.4 supercronic
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
2. Сбрасывает root до пользователя приложения (`APPLICATION_USER` /
   `APPLICATION_GROUP`, по умолчанию `unit:unit`) через `setpriv`.
3. `exec`-ит `supercronic`, пробрасывая любые аргументы, дописанные после
   команды `supercronic`, и подставляя путь к crontab по умолчанию, если он
   не передан (см. [Тонкая настройка supercronic](#тонкая-настройка-supercronic)).

#### Crontab по умолчанию

Образ поставляется с `/etc/supercronic/crontab`, содержащим одну задачу:

```cron
*/5 * * * * curl -fsS -o /dev/null "${DRUPAL_CRON_URL:-http://localhost:8080/cron.php}"
```

Переопределите его, смонтировав собственный файл по тому же пути:

```bash
-v "$PWD/crontab:/etc/supercronic/crontab:ro"
```

Или запеките собственный crontab в дочерний образ.

`DRUPAL_CRON_URL` должна содержать полный URL cron-эндпоинта Drupal,
включая cron-ключ (например,
`http://localhost:8080/cron.php?cron_key=YOUR_KEY`). Как альтернативу
можно смонтировать собственный crontab, вызывающий `vendor/bin/drush cron`
из Composer-проекта вместо HTTP-эндпоинта.

#### Тонкая настройка supercronic

Всё, что дописано после команды `supercronic`, пробрасывается напрямую раннеру,
поэтому его флаги не требуют пересборки образа:

```bash
# Перечитывать crontab при изменении (без перезапуска контейнера) и подробный лог
docker run -d --name drupal-cron \
  -v "$PWD/crontab:/etc/supercronic/crontab" \
  ghcr.io/6run0/freeunit-drupal:trixie-php8.4 supercronic -inotify -debug
```

Если завершающий аргумент указывает на читаемый файл, он используется как
crontab; иначе дописывается путь по умолчанию (`/etc/supercronic/crontab`),
так что добавление флага по-прежнему запускает встроенный crontab. Полный
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
- `handle_<cmd>` **обязан `exec`-нуть** финальный процесс. Возврат или
  выход с ненулевым кодом — фатальное нарушение контракта.
- Не затеняйте имена функций базовой библиотеки и переменные
  `APPLICATION_*` / `UNIT_ENTRYPOINT_*`.

### Соглашения `/docker-entrypoint.d/`

Этот образ наследует обработку `/docker-entrypoint.d/` базового entrypoint
без изменений. Файлы применяются в лексическом порядке, по расширению:

| Расширение | Действие |
|------------|----------|
| `*.sh`     | Исполняется от root. |
| `*.pem`    | Загружается как набор сертификатов с именем файла (без `.pem`). |
| `*.json`   | Отправляется `PUT`-запросом в `config` Unit через управляющий сокет. |

Файлы прочих типов логируются и игнорируются.

> Несколько `*.json` **не** объединяются: `PUT /config` заменяет всю
> конфигурацию, поэтому в силу вступает только лексически последний файл
> (entrypoint предупреждает, если их больше одного). Поставляйте один
> объединённый файл конфигурации.

В cron-роли `*.sh` дроп-ины выполняются, но `*.pem` и `*.json` не
обрабатываются (Unit в этой роли не запускается).

### Почта (msmtp)

`mail()` PHP вызывает `/usr/sbin/sendmail`, который в этом образе симлинкован
на `msmtp`. Поставляемый `/etc/msmtprc` — **закомментированный шаблон без
активных настроек**: почта остаётся ненастроенной, пока вы не укажете свой
SMTP-релей — раскомментируйте и отредактируйте шаблон в дочернем образе или
смонтируйте собственный конфиг по тому же пути:

```bash
-v "$PWD/msmtprc:/etc/msmtprc:ro"
```

Не храните учётные данные в этом общедоступном для чтения файле: шаблон
использует `passwordeval`, читающий пароль из смонтированного секрета
(например, `/run/secrets/smtp_password`) вместо строки `password` открытым
текстом.

## Переменные окружения

Переменные, унаследованные от базового образа (`APPLICATION_*` и
`UNIT_ENTRYPOINT_QUIET_LOGS`), описаны в
[README freeunit-php](https://github.com/6RUN0/docker-freeunit-php#environment-variables).
Этот образ добавляет одну собственную переменную:

| Переменная | По умолчанию | Назначение |
|------------|--------------|------------|
| `DRUPAL_CRON_URL` | _не задана_ | URL cron-эндпоинта Drupal (включая cron-ключ), используемый crontab по умолчанию. При отсутствии используется `http://localhost:8080/cron.php`. |

## Модель безопасности

Мастер-процесс Unit и cron-роль оба требуют `CAP_SETUID` и `CAP_SETGID` —
мастер для порождения воркеров, хук cron — для сброса root через `setpriv`.
Запускайте с:

```bash
docker run --cap-drop=ALL \
  --cap-add=SETUID \
  --cap-add=SETGID \
  --security-opt=no-new-privileges \
  ...
```

Сбрасывайте привилегии для самого приложения Drupal через ключи `user`/`group`
в конфиге Unit (веб-роль) или через `APPLICATION_USER` / `APPLICATION_GROUP`
(cron-роль — `handle_supercronic` передаёт их в `exec_as_user`).

Относитесь к `/docker-entrypoint.d/*.sh` как к доверенному вводу — эти
скрипты исполняются от root внутри контейнера.

## См. также

- [Список изменений](CHANGELOG.ru.md)
- [Базовый образ freeunit-php](https://github.com/6RUN0/docker-freeunit-php)
- [FreeUnit (апстрим)](https://github.com/freeunitorg/freeunit)
- [supercronic](https://github.com/aptible/supercronic)
- [Unit в Docker на unit.nginx.org](https://unit.nginx.org/howto/docker/)
