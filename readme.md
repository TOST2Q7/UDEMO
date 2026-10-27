# UDEMO — ветка `checks`

Набор bash-скриптов, которые разворачивают учебный сетевой стенд компании
`au-team.irpo` на ALT Linux: провайдер, два офиса с маршрутизаторами,
межсетевой экран филиала (BR-FW),
GRE + OSPF между ними, VLAN, DHCP, DNS, NTP, RAID + NFS, SSH, Ansible,
домен Samba AD, сайт на LAMP и приложение в Docker за обратным прокси nginx,
HTTPS на ГОСТ-сертификатах. Каждый скрипт после настройки сам
проверяет результат и пишет лог `*-check.log`.

## Документация

Документация объясняет **зачем** нужен каждый элемент настройки, **как** он
работает и **почему** сделан именно так.

| Документ | О чём |
|---|---|
| [00-overview.md](docs/00-overview.md) | топология, адресный план, порядок запуска, сквозные решения (etcnet, DNS, chrony, ALT-специфика) |
| [01-script-skeleton.md](docs/01-script-skeleton.md) | общий каркас всех скриптов: переменные, `check()`, `retry`/`delete`, самоудаление, NEXT STEP, `exec bash` |
| [02-isp.md](docs/02-isp.md) | `isp.sh` — провайдер: часовой пояс, сервер времени, адреса, NAT, SSH |
| [03-hq-rtr.md](docs/03-hq-rtr.md) | `hq-rtr.sh`, `hq-rtr-2.sh` — VLAN, DHCP, GRE, OSPF, NAT и проброс 8080, `net_admin` |
| [04-br-rtr.md](docs/04-br-rtr.md) | `br-rtr.sh` — маршрутизатор филиала, проброс SSH и 8080, линк до BR-FW |
| [05-hq-srv.md](docs/05-hq-srv.md) | `hq-srv.sh`, `dnsmasq.conf` — DNS, RAID 0, NFS, `sshuser` |
| [06-hq-cli.md](docs/06-hq-cli.md) | `hq-cli.sh` — клиент: браузер, NFS, SSH |
| [07-br-srv.md](docs/07-br-srv.md) | `br-srv.sh`, `inventory2.yml`, `get_hostname.yml` — Ansible |
| [08-samba.md](docs/08-samba.md) | `samba.sh` — контроллер домена AD, пользователи, время |
| [09-web-services.md](docs/09-web-services.md) | `web.sh`, `docker.sh`, `proxy.sh` — сайт на LAMP, testapp в Docker, обратный прокси nginx |
| [10-gost.md](docs/10-gost.md) | `gost.sh`, `gost-isp.sh`, `gost-hqcli.sh` — УЦ и HTTPS на ГОСТ |
| [11-notes.md](docs/11-notes.md) | особенности, допущения, внешние зависимости, подводные камни |
| [12-br-fw.md](docs/12-br-fw.md) | `br-fw.sh` — межсетевой экран филиала: OSPF, правила iptables, `net_admin` |
| [13-extra.md](docs/13-extra.md) | `samba-users.sh`, `fail2ban.sh`, `cups.sh`, `atop.sh` — импорт пользователей, защита SSH, печать, мониторинг |

## Порядок запуска (кратко)

```
ISP → HQ-RTR, BR-RTR → BR-FW → HQ-SRV → HQ-RTR (hq-rtr-2.sh) → HQ-CLI
    → BR-SRV (br-srv.sh, затем samba.sh, samba-users.sh)
    → HQ-SRV (web.sh), BR-SRV (docker.sh) → ISP (proxy.sh)
    → HQ-SRV (gost.sh) → ISP (gost-isp.sh) → HQ-CLI (gost-hqcli.sh)
    HQ-SRV: fail2ban.sh, cups.sh в любой момент после hq-srv.sh; atop.sh — по заданию
```

Почему именно так — в [00-overview.md](docs/00-overview.md#3-порядок-запуска-и-почему-он-такой).

**Подсказка NEXT STEP** в конце каждого скрипта сохраняется рядом с ним в
`<скрипт>-next-step.txt` (например, `cat isp-next-step.txt`). У `isp.sh` на
экране короткая версия, полная — в файле.

**VLAN для HQ-SRV и HQ-CLI — два сценария:** Proxmox ставит тег сам
(`VLAN Tag = 100/200` у их карт, адрес на `enp7s1`) или ВМ тегирует сама
(`enp7s1.100` / `enp7s1.200`). `hq-rtr.sh` в конце спрашивает, какой
сейчас (Enter — Proxmox; без вопроса: `VLAN_MODE=manual ./hq-rtr.sh`), и
печатает шаги только для него; другой вариант — `./hq-srv-steps manual`
или `./hq-srv-steps proxmox`. Подробно — [00-overview.md §4.8](docs/00-overview.md#48-как-vlan-100200-доходит-до-hq-srv-и-hq-cli-два-сценария).
