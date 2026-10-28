# 04. BR-RTR — `br-rtr.sh`

**Роль узла.** Пограничный маршрутизатор филиала. Зеркальная копия HQ-RTR,
но проще: в филиале один сервер, поэтому **нет VLAN и нет DHCP**. Как и на
HQ-RTR, снаружи пробрасываются SSH и порт веб-приложения на сервер филиала.
BR-SRV подключён к BR-RTR **напрямую**: `enp7s2` — LAN филиала, BR-RTR —
её шлюз.

**Интерфейсы.**

| Интерфейс | Назначение | Адрес |
|---|---|---|
| `enp7s1` | WAN, к ISP | `172.16.2.2/28` (задаётся руками до скрипта) |
| `enp7s2` | LAN филиала (BR-SRV) | `192.168.0.1/28` |
| `tun0` | GRE-туннель в HQ-RTR | `10.10.10.2/24` |

Всё, что устроено так же, как на HQ-RTR, здесь описано кратко со ссылками —
подробные объяснения в [03-hq-rtr.md](03-hq-rtr.md).

---

## 1. Имя хоста, `shadow-groups`, forwarding

```bash
hostnamectl set-hostname br-rtr.tkhis.pro
apt-get install -y shadow-groups
sed -i 's/^#* *net\.ipv4\.ip_forward *=.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
grep -q "^net.ipv4.ip_forward = 1" /etc/net/sysctl.conf || echo "net.ipv4.ip_forward = 1" >> /etc/net/sysctl.conf
sysctl -w net.ipv4.ip_forward=1
```

Смысл тот же, что на HQ-RTR, и forwarding включается так же: в любом
написании строки и сразу, через `sysctl -w` (см.
[02-isp.md §5](02-isp.md#5-маршрутизация-ip-forwarding)).

## 2. LAN-интерфейс `enp7s2`

```bash
mkdir -p /etc/net/ifaces/enp7s2
cat > /etc/net/ifaces/enp7s2/options <<EOF
TYPE=eth
BOOTPROTO=static
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF
echo "192.168.0.1/28" > /etc/net/ifaces/enp7s2/ipv4address
```

В отличие от HQ-RTR, здесь `enp7s2` — **не trunk**, а обычный порт с
адресом: в филиале один сегмент, и VLAN бы только усложнили конфигурацию
без пользы. `/28` — до 14 узлов, `.1` — шлюз (этот BR-RTR), `.2` — BR-SRV.

`options` пишется целиком, а не копируется с `enp7s1`: если на WAN ещё
остался `BOOTPROTO=dhcp`, копия унаследовала бы его, и etcnet не назначил
бы `enp7s2` адрес из `ipv4address` — BR-SRV остался бы без шлюза.

## 3. GRE-туннель

```bash
TUNLOCAL=172.16.2.2
TUNREMOTE=172.16.1.2
...
echo "10.10.10.2/24" > /etc/net/ifaces/tun0/ipv4address
```

Зеркало настроек HQ-RTR: `LOCAL` и `REMOTE` меняются местами, внутренний
адрес — второй в `10.10.10.0/24`. Все остальные параметры (`TYPE`, `TUNTYPE`, `TTL`,
`HOST`) **обязаны совпадать** по смыслу с HQ-RTR, иначе туннель не
поднимется. Подробнее — [03-hq-rtr.md §1.6](03-hq-rtr.md#16-gre-туннель-tun0).

## 4. OSPF

```
router ospf
no network 192.168.1.0/30 area 0
network 192.168.0.0/28 area 0
network 10.10.10.0/24 area 0
int tun0
ip ospf authentication message-digest
ip ospf message-digest-key 1 md5 P@ssw0rd
ip ospf network broadcast
```

OSPF включён на LAN филиала и на туннеле: BR-RTR сам объявляет
`192.168.0.0/28` в HQ. `no network 192.168.1.0/30` убирает линк до BR-FW,
если маршрутизатор настраивали прежней версией скрипта (на чистом FRR
vtysh лишь сообщит, что такой сети нет). **Ключ и номер ключа совпадают** с HQ-RTR — это
обязательное условие установления соседства с MD5-аутентификацией.
**Тип сети на `tun0` — broadcast**, как на HQ-RTR: типы на двух концах
должны совпадать. После схождения OSPF BR-RTR знает три VLAN головного
офиса, а HQ-RTR — `192.168.0.0/28`.

## 5. Пользователь `admin`, SSH

Идентично HQ-RTR ([§1.9–1.10](03-hq-rtr.md#19-пользователь-admin)).

## 6. NAT и проброс портов

```bash
iptables -t nat -A POSTROUTING -o enp7s1 -j MASQUERADE
iptables -t nat -A PREROUTING -i enp7s1 -p tcp --dport 2127 -j DNAT --to-destination 192.168.0.2:2127
iptables -t nat -A PREROUTING -i enp7s1 -p tcp --dport 8080 -j DNAT --to-destination 192.168.0.2:8080
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables
```

**MASQUERADE** — как на HQ-RTR.

**DNAT** — проброс: TCP-соединения, пришедшие **снаружи** на порт 2127
маршрутизатора, перенаправляются на `192.168.0.2:2127` (SSH BR-SRV). Так
к серверу филиала можно подключиться по WAN-адресу роутера
(`ssh -p 2127 userssh@172.16.2.2`), хотя сам сервер в частной сети.

Разбор:
* `PREROUTING` — цепочка «до маршрутизации»: адрес назначения надо
  подменить **до** того, как ядро решит, куда отправлять пакет;
* `-i enp7s1` — только пакеты, **пришедшие с WAN**;
* `--dport 2127` — только этот порт;
* `DNAT --to-destination` — подмена адреса (и порта) назначения; ответы
  автоматически получат обратную подмену благодаря conntrack.

**Почему `-i enp7s1`, а не `-d <адрес>`.** Комментарий в скрипте прямо
объясняет: на маршрутизаторе **тоже** работает SSH на порту 2127. Если бы
правило совпадало по LAN-адресу роутера (как в закомментированной заготовке
на HQ-RTR), то попытка администратора зайти на сам BR-RTR по SSH
превращалась бы в вход на BR-SRV. Привязка к входному WAN-интерфейсу
разделяет эти случаи: снаружи → на сервер, изнутри/через туннель → на
роутер.

**Проброс 8080.** Второе DNAT-правило устроено так же и ведёт на
контейнер `testapp` на BR-SRV (`docker.sh`), порт 8080 → 8080. Через него
обратный прокси на ISP достаёт до `docker.tkhis.pro`
([09-web-services.md](09-web-services.md)).

## 7. Синхронизация времени

chrony-клиент с сервером `172.16.2.1` — ближайший к филиалу адрес ISP
(см. [00-overview.md §4.6](00-overview.md#46-синхронизация-времени-chrony)).

## 8. DNS

`resolv.conf` → HQ-SRV (`192.168.100.2`). До HQ-SRV BR-RTR доходит через
туннель по маршруту, который узнал из OSPF. Пока туннель/OSPF не поднялись,
разрешение имён на BR-RTR не работает.

## 9. Проверки

Сверх стандартных:

* `IP forwarding active now` — пересылка включена в ядре, а не только в
  файле.
* `WAN 172.16.2.2/28 on enp7s1`, `ISP reachable (172.16.2.1)`,
  `HQ-RTR WAN reachable (172.16.1.2)` — подложка туннеля. Если здесь FAIL,
  GRE не поднимется, и искать надо в WAN/ISP, а не в настройках `tun0`.
* `Address 192.168.0.1/28 on enp7s2 (BR LAN)` — шлюз филиала на месте.
* `BR-SRV reachable (192.168.0.2)` — прямая связь с сервером филиала. При
  первом прогоне FAIL нормален: BR-SRV настраивается следующим.
* `Interface tun0 (GRE) is up` — у интерфейса есть флаг `UP`, а не просто
  он существует.
* `tun0 is GRE 172.16.2.2 -> 172.16.1.2` — `ip -d link` показывает, что это именно GRE
  с правильными внешними адресами: перепутанные `TUNLOCAL`/`TUNREMOTE`
  дали бы интерфейс, который «есть», но никуда не ведёт.
* `Tunnel to HQ-RTR responds (10.10.10.1)` — пинг **HQ-RTR** по туннелю
  (`10.10.10.1` — его конец туннеля).
* `OSPF route to HQ responds (192.168.100.1)` — самая показательная
  проверка: этот адрес BR-RTR может знать **только** из OSPF. Если она OK —
  туннель, аутентификация и обмен маршрутами работают целиком. На
  broadcast-туннеле соседство поднимается около 40 с, поэтому перед
  проверками скрипт до ~60 с ждёт, пока этот адрес начнёт отвечать.
* `OSPF network type on tun0 is broadcast` — тип сети совпадает с HQ-RTR.
* `OSPF neighbour 10.10.10.1 is Full on tun0` — соседство с HQ-RTR
  установлено полностью.
* `SSH DNAT (2127) configured`, `testapp DNAT (8080) configured` —
  `iptables -C` с точно теми же правилами.
* `Time synced from ISP (172.16.2.1)` — chrony выбрал этот источник.

## 10. NEXT STEP

Следующий — **BR-SRV** (`br-srv.sh`). Команды для него: `BOOTPROTO=static`,
статический `192.168.0.2/28`, шлюз `192.168.0.1`, временный DNS
`77.88.8.8` на `enp7s1`.
