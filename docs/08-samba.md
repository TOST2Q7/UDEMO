# 08. Samba AD DC — `samba.sh` (на BR-SRV)

**Роль.** Превращает BR-SRV в **контроллер домена Active Directory**
`AU-TEAM.IRPO` на базе Samba. Это централизованная база пользователей и
групп: вместо локальных учёток на каждой машине — одна доменная учётка,
которой можно входить на любой машине домена.

Запускается на BR-SRV **после** `br-srv.sh` и требует работающего HQ-SRV
(DNS-пересылка).

---

## 1. Установка

```bash
apt-get update
apt-get install -y task-samba-dc
```

`task-samba-dc` — метапакет ALT («task» = набор пакетов под задачу): сам
Samba в роли DC, Kerberos-клиент, утилиты `samba-tool`, `kinit` и т. д.
Один пакет вместо ручного перечисления десятка зависимостей.

## 2. Отключение конфликтующих служб

```bash
for service in smb nmb krb5kdc slapd bind; do
  systemctl disable $service --now
done
```

Samba в роли DC — **монолитная служба `samba`**, которая сама реализует
файловый сервер, NetBIOS, Kerberos KDC, LDAP и (с `SAMBA_INTERNAL`) DNS. Если
параллельно работают отдельные демоны, они займут те же порты (445, 137,
88, 389, 53), и `samba` не запустится:

| Служба | Что это | Конфликтует по порту |
|---|---|---|
| `smb` | файловый сервер Samba (роль member/standalone) | 445/139 |
| `nmb` | NetBIOS-имена | 137/138 |
| `krb5kdc` | MIT Kerberos KDC | 88 |
| `slapd` | OpenLDAP | 389 |
| `bind` | DNS-сервер BIND | 53 |

`disable --now` — остановить сейчас и убрать из автозапуска.

## 3. Очистка следов прежних конфигураций

```bash
rm -f /etc/samba/smb.conf
rm -f /etc/cache/smb.conf
rm -rf /var/lib/samba
rm -rf /var/cache/samba
mkdir -p /var/lib/samba/sysvol
```

`samba-tool domain provision` **отказывается** работать, если
`smb.conf` уже существует, а старые базы в `/var/lib/samba` привели бы к
конфликтам. Поэтому всё стирается, и провижининг идёт с чистого листа. Это
же делает скрипт **перезапускаемым**: повторный запуск через `retry`
пересоздаст домен заново.

`sysvol` — общий каталог домена (групповые политики, скрипты входа);
создаётся заранее, т. к. провижининг ожидает его наличия.

## 4. Создание домена

```bash
samba-tool domain provision \
  --realm="AU-TEAM.IRPO" \
  --domain="AU-TEAM" \
  --server-role="dc" \
  --dns-backend="SAMBA_INTERNAL" \
  --option="dns forwarder=192.168.100.2" \
  --adminpass="P@ssw0rd"
```

| Параметр | Смысл | Почему так |
|---|---|---|
| `--realm=AU-TEAM.IRPO` | Kerberos-realm = DNS-имя домена заглавными | по соглашению AD realm совпадает с DNS-доменом `au-team.irpo`, которым уже пользуется весь стенд |
| `--domain=AU-TEAM` | NetBIOS-имя домена (короткое, до 15 символов) | для совместимости со старыми клиентами и форм входа `AU-TEAM\user` |
| `--server-role=dc` | контроллер домена | а не рядовой участник или отдельный сервер |
| `--dns-backend=SAMBA_INTERNAL` | встроенный DNS Samba | не нужен отдельный BIND; AD **обязан** иметь DNS для своих SRV-записей, и встроенный вариант — самый простой |
| `dns forwarder=192.168.100.2` | всё, что не в зоне AD, пересылать на HQ-SRV | так DC продолжает резолвить и внутренние записи dnsmasq, и интернет |
| `--adminpass` | пароль `Administrator` | требование задания; без параметра был бы сгенерирован случайный |

## 5. Запуск и Kerberos

```bash
systemctl enable --now samba
/bin/cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
systemctl restart samba
```

Провижининг генерирует правильный `krb5.conf` для нового realm-а. Его нужно
положить в `/etc/krb5.conf`, иначе системные Kerberos-утилиты (`kinit`) не
будут знать, где KDC для `AU-TEAM.IRPO`.

`/bin/cp -f` — вызов бинарника по полному пути в обход возможного алиаса
`cp -i`, который спросил бы подтверждение перезаписи.

## 6. Временное переключение DNS на себя

```bash
cat > "/etc/net/ifaces/enp7s1/resolv.conf" <<EOF
search au-team.irpo
nameserver 127.0.0.1
EOF
systemctl restart network
echo "P@ssw0rd" | kinit Administrator@AU-TEAM.IRPO
```

`kinit` должен найти KDC домена через DNS (SRV-запись
`_kerberos._udp.au-team.irpo`), а её сейчас знает только сам DC. Поэтому на
время административных операций сервер смотрит в собственный DNS.
`kinit` получает Kerberos-билет администратора — после этого `samba-tool`
может выполнять изменения в домене. Пароль подаётся через stdin, чтобы не
было интерактивного запроса.

## 7. Группа и пользователи

```bash
samba-tool group add hq
for i in {1..5}; do
  samba-tool user add hquser$i P@ssw0rd
  samba-tool user setexpiry hquser$i --noexpiry
  samba-tool group addmembers "hq" hquser$i
done
```

Требование задания: доменная группа `hq` и пять пользователей
`hquser1…hquser5` в ней.

* `setexpiry --noexpiry` — по умолчанию в AD пароль истекает через 42 дня;
  для стенда это отключено, чтобы учётки не «протухли» к проверке.
* Группа нужна, чтобы назначать права не каждому, а сразу группе (например,
  sudo-права для `%hq` на клиентах домена).

## 8. Синхронизация времени

```bash
cat > /etc/chrony.conf <<EOF
server 172.16.2.1 iburst
EOF
systemctl restart chronyd
```

**Почему это важно именно здесь.** Kerberos — основа AD — отвергает
аутентификацию, если часы клиента и KDC расходятся больше чем на 5 минут.
DC должен иметь точное время, которое затем используют клиенты домена.

* `172.16.2.1` — адрес ISP со стороны филиала: ISP — ближайшая к «внешнему
  миру» машина, и по легенде стенда источником времени служит он.
* `iburst` — при старте отправить серию запросов, чтобы синхронизироваться
  за секунды, а не минуты.
* Файл перезаписывается целиком (`>`), чтобы в нём не осталось серверов
  из стандартного пула, недоступных из изолированного стенда.

Сейчас тот же клиент уже настроен в `br-srv.sh`, и ISP раздаёт время
(`isp.sh`), так что в `samba.sh` этот блок фактически повторяет
существующую настройку — это безвредно и делает `samba.sh`
самодостаточным.

## 9. Возврат DNS на HQ-SRV

```bash
cat > /etc/net/ifaces/enp7s1/resolv.conf <<EOF
nameserver 192.168.100.2
search au-team.irpo
EOF
cp /etc/net/ifaces/enp7s1/resolv.conf /etc/resolv.conf
```

Итоговая схема — **единая точка входа DNS** для всех узлов, включая DC:

```
любой узел ─► HQ-SRV (dnsmasq)
                ├─ свои записи (hq-srv, br-rtr, …)       → отвечает сам
                ├─ прочие *.au-team.irpo (SRV AD и т.п.)  → BR-SRV (Samba DNS)
                └─ всё остальное                           → 77.88.8.8
BR-SRV (Samba DNS) ─ не своя зона ─► HQ-SRV
```

Так DC тоже видит записи, заведённые только в dnsmasq, а AD-записи
доступны всем узлам через HQ-SRV.

## 10. Проверки

| Проверка | Смысл |
|---|---|
| `samba` active / enabled | DC работает и стартует при загрузке |
| `samba-tool domain info 127.0.0.1` | DC отвечает как контроллер домена (LDAP/CLDAP), домен реально создан |
| `/etc/krb5.conf copied` | Kerberos настроен |
| `group list \| grep -qw hq` | `-w` — целое слово, чтобы не совпало, например, с `hq-admins` |
| `user list \| grep -qw hquserN` | каждый из пяти пользователей |
| chronyd / `server 172.16.2.1` | синхронизация времени |
| DNS → 192.168.100.2 | итоговое состояние resolv.conf |

Вызов `check` внутри цикла `for i in 1 2 3 4 5` использует **двойные**
кавычки — чтобы `$i` подставился на каждой итерации.

## 11. NEXT STEP

Указывает на `docker.sh` на этом же сервере (нужен ISO задания в
`/dev/sr0`) — см. [09-web-services.md](09-web-services.md).
