# 09. Веб-сервисы — `web.sh`, `docker.sh`, `proxy.sh`

**Задача этапа.** Поднять два веб-приложения и опубликовать их под
именами `web.au-team.irpo` и `docker.au-team.irpo` через единый обратный
прокси на ISP. Позже этот же прокси переводится на HTTPS
([10-gost.md](10-gost.md)).

## Общая схема прохождения запроса

```
HQ-CLI (браузер)
   │  http://web.au-team.irpo          /etc/hosts: web, docker → 172.16.1.1
   ▼
ISP nginx :80 (позже :443)  ── proxy.sh / gost-isp.sh
   │  по имени сайта (заголовок Host / SNI) выбирает бэкенд
   ├── web    → 172.16.1.2:8080 ─► HQ-RTR DNAT ─► 192.168.100.2:80   (HQ-SRV, Apache + PHP + MariaDB)
   └── docker → 172.16.2.2:8080 ─► BR-RTR DNAT ─► 192.168.0.2:8080   (BR-SRV, Docker: testapp + MariaDB)
```

**Почему прокси именно на ISP.** По легенде ISP — точка на границе с
внешним миром, а оба офиса спрятаны за NAT. Прокси «снаружи» — это
единая точка входа: пользователю не нужно знать, в каком офисе на самом
деле работает сервис, а на прокси же удобно навесить аутентификацию и
TLS.

**Почему бэкенды адресуются через WAN-адреса роутеров**, а не напрямую
(`192.168.100.2`, `192.168.0.2`): ISP не знает частных сетей офисов — они
видны только через туннель, к которому ISP не причастен. До ISP «дотягиваются»
лишь WAN-адреса маршрутизаторов, поэтому на каждом роутере сделан проброс
порта 8080 внутрь офиса (DNAT, см. [03-hq-rtr.md §1.8](03-hq-rtr.md#18-nat)
и [04-br-rtr.md §6](04-br-rtr.md#6-nat-и-проброс-портов)).

**Порядок.** `web.sh` (HQ-SRV) и `docker.sh` (BR-SRV) — в любом порядке,
затем `proxy.sh` (ISP). Прокси запускается последним, потому что его
проверки обращаются к обоим бэкендам по-настоящему.

**Образ экзамена (ISO).** И сайт, и Docker-образы берутся не из интернета,
а с компакт-диска задания, подключённого к ВМ как `/dev/sr0`. Оба скрипта
монтируют его в `/mnt`, если он ещё не смонтирован (`mountpoint -q … ||
mount …`), и предупреждают, если нужного каталога на диске нет.

---

## Часть 1. `web.sh` (HQ-SRV) — сайт на LAMP

### 1.1. Переменные

| Переменная | Значение | Смысл |
|---|---|---|
| `ISO_DEV`, `ISO_MNT` | `/dev/sr0`, `/mnt` | откуда брать файлы сайта |
| `WEB_ROOT` | `/var/www/html` | корень сайта Apache в ALT |
| `DB_NAME`, `DB_USER`, `DB_PASS` | `webdb`, `web1`, `P@ssw0rd` | БД и учётка приложения — требование задания |

### 1.2. Пакеты

```bash
apt-get install -y lamp-server curl
```

`lamp-server` — метапакет ALT: **L**inux + **A**pache (`httpd2`) +
**M**ariaDB + **P**HP с модулем для Apache. Один пакет вместо ручного
подбора совместимых версий. `curl` нужен для финальной проверки ответа
сайта.

### 1.3. Файлы сайта

```bash
cp "$ISO_MNT/web/index.php" "$ISO_MNT/web/logo.png" "$WEB_ROOT/"
rm -f "$WEB_ROOT/index.html"
```

Приложение — PHP-страница с логотипом из ISO. Стандартная заглушка
`index.html` удаляется: в настройке `DirectoryIndex` Apache она стоит
раньше `index.php`, и вместо сайта открывалась бы страница «It works!».

### 1.4. Параметры подключения к БД

```bash
sed -i "s/\$username = \"user\";/\$username = \"$DB_USER\";/" "$WEB_ROOT/index.php"
…password…, …dbname…
```

В `index.php` из ISO зашиты заглушки `user`/`password`/`db`. `sed`
заменяет их на реальные значения. Шаблон включает имя PHP-переменной,
кавычки и `;` — чтобы заменить **только** строку присваивания, а не любое
вхождение слова `user`. `\$` — чтобы bash не принял `$username` за свою
переменную.

### 1.5. MariaDB

```sql
CREATE DATABASE IF NOT EXISTS webdb;
CREATE USER IF NOT EXISTS 'web1'@'localhost' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON webdb.* TO 'web1'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
```

* `mariadb -u root` без пароля — в свежей установке ALT root MariaDB входит
  через unix-сокет от системного root.
* `IF NOT EXISTS` — повторный запуск не падает.
* `'web1'@'localhost'` — пользователь может подключаться **только с этой же
  машины**: сайт и БД на одном сервере, удалённый доступ к БД не нужен.
* Права только на `webdb.*` — приложению незачем видеть другие БД.
* `FLUSH PRIVILEGES` — перечитать таблицы прав (после `GRANT` формально не
  обязательно, но безвредно и привычно).

```bash
if [ -z "$(mariadb … -N -e 'SHOW TABLES' webdb)" ]; then
    mariadb … webdb < "$ISO_MNT/web/dump.sql"
fi
```

Дамп с данными сайта импортируется **только в пустую БД** — повторный
запуск не упадёт на «таблица уже существует» и не задвоит данные. `-N` —
без строки заголовков, чтобы пустой результат был действительно пустым.

### 1.6. Apache

`systemctl enable --now httpd2` + `restart` — в ALT Apache 2 называется
`httpd2`. Рестарт нужен, чтобы подхватить модуль PHP, установленный
вместе с `lamp-server`.

Сайт слушает обычный **порт 80**. Порт 8080 появляется только на WAN
HQ-RTR — проброс `8080 → 192.168.100.2:80`. Смена порта на роутере
позволяет не трогать конфигурацию Apache.

### 1.7. Проверки

Кроме файлов и сервисов:
* `web1 can log in to webdb` — учётка и права реально работают;
* `Dump imported` — в БД есть таблицы;
* `Site answers 200 on port 80` — `curl` к `127.0.0.1` возвращает HTTP 200:
  PHP выполнился и не упал на подключении к БД.

`delete` удаляет только служебные файлы — сайт и БД остаются.

---

## Часть 2. `docker.sh` (BR-SRV) — приложение в контейнерах

### 2.1. Переменные

| Переменная | Значение | Смысл |
|---|---|---|
| `COMPOSE_DIR` | `/opt/testapp` | `/opt` — стандартное место для стороннего ПО |
| `APP_PORT` | `8080` | порт приложения на хосте |
| `DB_NAME`, `DB_USER`, `DB_PASS` | `testdb`, `testc`, `P@ssw0rd` | требование задания |
| `DB_ROOT_PASS` | `toor` | пароль root внутри контейнера MariaDB (образ без него не стартует) |

### 2.2. Docker

```bash
apt-get install -y docker-engine docker-compose-v2 curl
systemctl enable --now docker.service
```

`docker-engine` — сам Docker в ALT; `docker-compose-v2` — плагин,
добавляющий команду `docker compose` (вторая версия, встроенная в CLI, а не
отдельная Python-утилита `docker-compose`).

### 2.3. Загрузка образов с ISO

```bash
load_image() {
    docker load -i "$1" | sed -n 's/^Loaded image: //p' | tail -n 1
}
APP_IMAGE="$(load_image "$ISO_MNT/docker/site_latest.tar")"
DB_IMAGE="$(load_image "$ISO_MNT/docker/mariadb_latest.tar")"
APP_IMAGE="${APP_IMAGE:-site:latest}"
```

**Почему не `docker pull`.** На экзаменационном стенде доступа к Docker Hub
может не быть; образы выданы файлами на ISO.

**Почему имя образа берётся из вывода `docker load`**, а не пишется жёстко.
`docker load` печатает `Loaded image: <имя:тег>` — тот тег, под которым
образ был сохранён. Если в compose указать другое имя, Docker не найдёт
образ локально и **попытается скачать** его из интернета. Взяв имя из
вывода, скрипт гарантирует, что compose использует именно загруженный
образ. `${…:-site:latest}` — запасное значение, если вывод не распознан.

### 2.4. `compose.yaml`

```yaml
services:
  database:
    container_name: db
    image: <mariadb>
    restart: always
    ports: ["3306:3306"]
    environment:
      MARIADB_DATABASE / MARIADB_USER / MARIADB_PASSWORD / MARIADB_ROOT_PASSWORD
  app:
    container_name: testapp
    image: <site>
    restart: always
    ports: ["8080:8000"]
    environment:
      DB_TYPE: maria, DB_HOST: database, DB_PORT: 3306, DB_NAME/USER/PASS
    depends_on: [database]
```

| Элемент | Зачем |
|---|---|
| `container_name: db` / `testapp` | фиксированные имена — **требование задания**; по ним же работают проверки `docker inspect` |
| `restart: always` | контейнеры поднимаются после перезагрузки сервера и при падении — требование задания |
| `MARIADB_*` | официальный образ MariaDB при **первом** старте сам создаёт БД и пользователя по этим переменным |
| `ports: 3306:3306` | БД доступна и с хоста (например, для отладки) |
| `DB_HOST: database` | внутри compose-сети контейнеры видят друг друга **по имени сервиса** — IP знать не нужно |
| `ports: 8080:8000` | приложение внутри слушает 8000, снаружи опубликовано на 8080 — этот порт и пробрасывает BR-RTR |
| `depends_on` | стартовать приложение после БД (порядок запуска, но не готовность — см. ниже) |

Файл генерируется heredoc-ом с подстановкой переменных — единственный
источник значений остаётся в начале скрипта.

### 2.5. Запуск и ожидание

```bash
docker compose -f "$COMPOSE_DIR/compose.yaml" up -d
for i in $(seq 30); do
    curl -s -o /dev/null "http://127.0.0.1:$APP_PORT" && break
    sleep 2
done
```

`up -d` — создать и запустить в фоне. `depends_on` ждёт лишь **старта**
контейнера БД, а MariaDB при первом запуске ещё минуту инициализирует
данные. Цикл до 60 секунд ждёт, пока приложение начнёт отвечать, — иначе
финальная проверка дала бы ложный FAIL.

### 2.6. Проверки

Сервис docker, плагин compose, наличие образов, контейнеры `db` и
`testapp` в состоянии Running, политика перезапуска `always`, ответ на
порту 8080. `delete` не трогает контейнеры и `/opt/testapp`.

---

## Часть 3. `proxy.sh` (ISP) — обратный прокси nginx (HTTP)

### 3.1. Переменные

| Переменная | Значение | Смысл |
|---|---|---|
| `WEB_BACKEND` | `172.16.1.2:8080` | WAN HQ-RTR → DNAT на HQ-SRV:80 |
| `DOCKER_BACKEND` | `172.16.2.2:8080` | WAN BR-RTR → DNAT на BR-SRV:8080 |
| `VHOST` | `/etc/nginx/sites-available.d/default.conf` | раскладка конфигов nginx в ALT |
| `HTPASSWD` | `/etc/nginx/.htpasswd` | файл паролей для basic-auth |
| `AUTH_USER` / `AUTH_PASS` | `WEB` / `P@ssw0rd` | требование задания |

### 3.2. Пакеты и пароль

```bash
apt-get install -y nginx apache2-htpasswd curl
htpasswd -bc "$HTPASSWD" "$AUTH_USER" "$AUTH_PASS"
```

`htpasswd` (из пакета Apache-утилит, сам Apache не нужен) создаёт файл
пользователей в формате, который понимает nginx. `-c` — создать файл
заново (перезаписать), `-b` — пароль из командной строки, без
интерактивного ввода.

### 3.3. Виртуальные хосты

Два блока `server` на порту 80 — по одному на имя. Смысл директив
`proxy_pass`, `proxy_set_header …` и `auth_basic` подробно разобран в
[10-gost.md §2.4](10-gost.md#24-конфиг-nginx): `gost-isp.sh` позже
**перезаписывает этот же файл**, меняя только `listen 80` на
`listen 443 ssl` и добавляя сертификаты, и использует тот же
`.htpasswd`. Поэтому переход на HTTPS не меняет логику прокси.

Пароль стоит **только на `web`** — требование задания.

### 3.4. Включение

```bash
ln -sf "$VHOST" /etc/nginx/sites-enabled.d/
nginx -t
systemctl enable --now nginx
systemctl restart nginx
```

В ALT nginx читает конфиги из `sites-enabled.d/`, а хранятся они в
`sites-available.d/`; «включение» сайта — символическая ссылка (`-f` —
перезаписать, если уже есть).

### 3.5. Проверки — реальные HTTP-запросы

```bash
status() {
    curl -s -o /dev/null -w "%{http_code}" -H "Host: $1" "${@:2}" http://127.0.0.1/
}
```

Функция делает запрос к **самому прокси** (`127.0.0.1`), подставляя нужное
имя в заголовок `Host` — так проверяется выбор виртуального хоста без
участия DNS. `${@:2}` передаёт curl дополнительные аргументы (например,
логин).

| Проверка | Ожидание | Что доказывает |
|---|---|---|
| `web` без пароля | **401** | basic-auth действует |
| `web` с `WEB:P@ssw0rd` | **200** | пароль верный **и** вся цепочка ISP → HQ-RTR DNAT → Apache → MariaDB работает |
| `docker` | **200** | цепочка ISP → BR-RTR DNAT → testapp работает |

Код **502** означает, что nginx работает, но бэкенд не отвечает — то есть
не запущен `web.sh`/`docker.sh` или не работает проброс на роутере.
