# 13. Дополнительные задания — `samba-users.sh`, `fail2ban.sh`, `cups.sh`, `atop.sh`

Четыре отдельных скрипта под отдельные задания. Каждый построен на общем
каркасе ([01-script-skeleton.md](01-script-skeleton.md)): переменные,
настройка, `check()` с логом `*-check.log`, файлы `retry`/`delete`,
самоудаление, NEXT STEP, `exec bash`.

| Скрипт | Где | Когда |
|---|---|---|
| `samba-users.sh` | BR-SRV | после `samba.sh`, ISO задания в `/dev/sr0` |
| `fail2ban.sh` | HQ-SRV | после `hq-srv.sh` |
| `cups.sh` | HQ-SRV | после `hq-srv.sh` |
| `atop.sh` | машина из задания | в любой момент |

---

## 1. `samba-users.sh` — импорт пользователей из CSV

```bash
mountpoint -q "$ISO_MNT" || mount "$ISO_DEV" "$ISO_MNT"
cat > "$IMPORT" <<'EOF'
...
EOF
"$IMPORT" "$CSV"
```

Скрипт кладёт рядом с собой импортёр `import_user.sh` и запускает его на
`/mnt/Users.csv` с диска задания. Импортёр остаётся на диске: его можно
запустить снова на другом файле — `./import_user.sh <file.csv>`.

Что делает импортёр (столбцы CSV через `;`: имя, фамилия, должность,
телефон, OU, улица, индекс, город, страна, пароль):

1. **OU.** Пятый столбец без строки-заголовка (`NR>1`), уникальные
   значения (`sort | uniq`) → `samba-tool ou add OU=<ou>,DC=tkhis,DC=pro`.
2. **Пользователи.** Строка-заголовок (`First Name`) пропускается. Логин —
   `имя.фамилия` в нижнем регистре (`${firstName,,}`), пароль `P@ssw0rd1`,
   заполняются имя, фамилия, телефон и должность, пользователь кладётся в
   свою OU (`--userou="OU=$ou"`), срок действия пароля снят
   (`setexpiry --noexpiry`).

`mountpoint -q … ||` — как в `web.sh`: если ISO уже смонтирован (например,
`docker.sh` или `web.sh` сделали это раньше), повторный `mount` не нужен.

**Проверки.** Найден `Users.csv`, сохранён `import_user.sh` и главное —
`Every user from Users.csv is in the domain`: для каждой строки CSV
`samba-tool user show имя.фамилия` должен найти пользователя. CSV из
Windows бывает с `\r` в конце строк, поэтому проверка читает его через
`tr -d '\r'`.

## 2. `fail2ban.sh` — защита SSH

```bash
apt-get install -y fail2ban python3-module-systemd
sed -i 's/before = paths-altlinux.conf/before = paths-altlinux-systemd.conf/' "$JAIL"
# [sshd]: enabled = true, port = 2127, maxretry = 3, findtime = 10m, bantime = 1m
```

* **`paths-altlinux-systemd.conf`** и **`python3-module-systemd`** — в ALT
  sshd пишет в журнал systemd, а не в файл. С этим набором путей fail2ban
  читает журнал, иначе он не увидел бы ни одной неудачной попытки входа.
* **Секция `[sshd]`** в `jail.conf` включается и получает порт `2127`
  (SSH стенда работает не на 22) и лимиты: 3 неудачные попытки за
  10 минут → бан адреса на 1 минуту.
* Правки секции обёрнуты в `if ! … grep -qx "enabled = true"`: при
  повторном запуске (`./retry`) строки не добавятся второй раз.

**Проверки.** Каждый параметр секции `[sshd]` отдельно, служба запущена и
в автозагрузке, `fail2ban-client status sshd` отвечает (скрипт до 10 с
ждёт, пока jail поднимется после рестарта).

**Как показать работу.** С другой машины трижды ввести неверный пароль:
`ssh -p 2127 userssh@192.168.100.2`. На HQ-SRV `fail2ban-client status sshd`
покажет адрес в списке заблокированных, через минуту он оттуда уйдёт.

## 3. `cups.sh` — принт-сервер

```bash
apt-get install -y cups cups-pdf
systemctl enable --now cups
cupsctl --share-printers --remote-any
```

* **`cups-pdf`** — виртуальный принтер, который «печатает» в PDF: на стенде
  нет настоящего принтера.
* **`cupsctl --share-printers --remote-any`** — открыть общий доступ к
  принтерам и принимать клиентов из любой сети (по умолчанию CUPS слушает
  только локальную машину).

**Проверки.** Пакеты, служба, общий доступ (`_share_printers=1`), клиенты
из любой сети (`_remote_any=1`), порт `631` слушается и `lpstat -p`
показывает хотя бы один принтер. Если последняя проверка FAIL, PDF-принтер
не создался автоматически — его нужно добавить в веб-интерфейсе CUPS
(`http://hq-srv:631`).

**На HQ-CLI** принтер подключается как
`ipp://hq-srv.tkhis.pro:631/printers/<имя>` — имя показывает `lpstat -p`
на HQ-SRV.

## 4. `atop.sh` — мониторинг

```bash
cat > /etc/default/atop <<EOF
LOGOPTS="-R"
LOGINTERVAL=420
LOGGENERATIONS=28
LOGPATH=/var/log/atop
EOF
systemctl enable --now atop
systemctl restart atop
```

atop раз в `LOGINTERVAL` секунд (420 = 7 минут) пишет снимок состояния
системы и хранит `LOGGENERATIONS` (28) суточных файлов в `/var/log/atop`.
**Конфиг пишется до запуска службы** (и служба перезапускается): atop
читает его только при старте.

Посмотреть записанное: `atop -r /var/log/atop/atop_ГГГГММДД`.
