# 12. BR-FW — `br-fw.sh`

**Роль узла.** Межсетевой экран филиала. Стоит между BR-RTR и сетью
BR-SRV и решает, что пускать в сеть филиала. BR-RTR при этом остаётся
пограничным маршрутизатором: у него внешний адрес `172.16.2.2`, NAT и
проброс портов. Поэтому NAT на BR-FW нет — он только маршрутизирует и
фильтрует.

**Интерфейсы.**

| Интерфейс | Назначение | Адрес |
|---|---|---|
| `enp7s1` | WAN, к BR-RTR (интернет и туннель в HQ) | `192.168.1.2/30` (задаётся руками до скрипта) |
| `enp7s2` | LAN филиала, шлюз BR-SRV | `192.168.0.1/28` |

```
BR-RTR enp7s2 192.168.1.1/30 ── 192.168.1.2/30 enp7s1 BR-FW enp7s2 192.168.0.1/28 ── BR-SRV 192.168.0.2
```

Шлюз филиала `192.168.0.1` раньше был на BR-RTR, теперь он на BR-FW.
Поэтому BR-SRV перенастраивать не пришлось.

Порядок запуска: после `br-rtr.sh` (BR-FW выходит в интернет через
BR-RTR) и до `br-srv.sh` (BR-SRV выходит через BR-FW).

---

## 1. Переменные

```bash
WAN="enp7s1"
LAN="enp7s2"
INT_NETS="192.168.100.0/27,192.168.200.0/28,192.168.99.0/29,10.10.10.0/30,192.168.1.0/30"
BR_SRV="192.168.0.2"
FWD_PORTS="2027,8080"
```

Кроме стандартных переменных каркаса ([01-script-skeleton.md](01-script-skeleton.md)),
здесь вынесено всё, что нужно правилам экрана:

* **`INT_NETS`** — внутренние сети компании, которым в филиал можно всё:
  три VLAN головного офиса, туннель и линк до BR-RTR. Трафик из HQ и из
  интернета приходит на BR-FW через один и тот же `enp7s1`, поэтому
  различать их приходится по адресу источника.
* **`BR_SRV`, `FWD_PORTS`** — куда и какие порты BR-RTR пробрасывает из
  интернета: SSH (`2027`) и testapp (`8080`). DNAT не меняет адрес
  источника, поэтому на BR-FW такие пакеты выглядят как «из интернета к
  `192.168.0.2:2027`/`8080`».

## 2. Маршрутизация и LAN

```bash
sed -i "s/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/" "/etc/net/sysctl.conf"
cp -r /etc/net/ifaces/$WAN/options /etc/net/ifaces/$LAN/options
echo "192.168.0.1/28" > /etc/net/ifaces/$LAN/ipv4address
```

Как на маршрутизаторах ([04-br-rtr.md §2](04-br-rtr.md#2-интерфейс-enp7s2--линк-до-br-fw)).
`options` копируются с `enp7s1`, поэтому там до запуска должен стоять
`BOOTPROTO=static` — это первая команда в подсказке NEXT STEP из
`br-rtr.sh`.

## 3. OSPF

```
router ospf
network 192.168.1.0/30 area 0
network 192.168.0.0/28 area 0
int enp7s2
ip ospf passive
```

* `192.168.1.0/30` — по этой сети BR-FW становится соседом BR-RTR.
* `192.168.0.0/28` — сеть филиала. Объявляет её теперь BR-FW: BR-RTR
  узнаёт её из OSPF и передаёт по туннелю в HQ.
* **`ip ospf passive` на `enp7s2`.** Сеть объявляется, но Hello туда не
  уходят. Для межсетевого экрана это важно: никто в сети филиала не может
  стать OSPF-соседом и подсунуть свои маршруты.

Линк до BR-RTR — обычная Ethernet-сеть, тип OSPF по умолчанию broadcast,
соседство поднимается после выборов DR, примерно через 40 с. Поэтому
перед проверками скрипт до ~60 с ждёт, пока начнёт отвечать
`192.168.100.1`.

## 4. Межсетевой экран

Требование, на которое опирается набор правил (формулировка задания для
межсетевого экрана в сторону ISP): **обеспечить работу http, https, dns,
ntp, icmp echo и запретить остальные подключения из сети Интернет во
внутреннюю сеть.**

```bash
iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT
iptables -F INPUT; iptables -F FORWARD

# сам BR-FW
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i $WAN -p 89 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A INPUT -i $LAN -j ACCEPT
iptables -A INPUT -i $WAN -s $INT_NETS -j ACCEPT

# транзит
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i $LAN -o $WAN -j ACCEPT
iptables -A FORWARD -i $WAN -o $LAN -s $INT_NETS -j ACCEPT
iptables -A FORWARD -i $WAN -o $LAN -p icmp --icmp-type echo-request -j ACCEPT
iptables -A FORWARD -i $WAN -o $LAN -p tcp -m multiport --dports 80,443,53 -j ACCEPT
iptables -A FORWARD -i $WAN -o $LAN -p udp -m multiport --dports 53,123 -j ACCEPT
iptables -A FORWARD -i $WAN -o $LAN -d $BR_SRV -p tcp -m multiport --dports $FWD_PORTS -j ACCEPT

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables
```

**Транзит (`FORWARD`):**

| Откуда → куда | Что пропускается | Зачем |
|---|---|---|
| ответы на уже открытые соединения | всё (`ESTABLISHED,RELATED`) | чтобы работали ответы в обе стороны |
| LAN → наружу | всё | BR-SRV ходит в интернет (`apt-get`), к HQ (Ansible, DNS HQ-SRV), к ISP (NTP) |
| внутренние сети → LAN | всё | вход HQ-CLI в домен Samba, пересылка DNS `au-team.irpo` с HQ-SRV на BR-SRV, SSH из HQ |
| интернет → LAN | ping, http/https, dns, ntp | требование задания |
| интернет → BR-SRV | tcp `2027`, `8080` | проброс с BR-RTR: SSH и testapp (через прокси на ISP) |
| остальное из интернета | запрещено (`-P FORWARD DROP`) | требование задания |

**Сам BR-FW (`INPUT`):** ответы на свои запросы, OSPF (протокол 89) только
от BR-RTR, ping, всё из LAN и из внутренних сетей (в том числе SSH на
`2027` для `net_admin`). Из интернета на BR-FW — ничего. `OUTPUT` не
ограничен: BR-FW сам ходит за пакетами, к NTP на ISP и к DNS HQ-SRV.

**Почему политики ставятся последними, а перед очисткой — `ACCEPT`.** Если
поставить `DROP` до правил, на мгновение рвутся все соединения, включая SSH,
из которого может идти настройка. При повторном запуске (`./retry`)
политика `DROP` уже стоит, поэтому перед `-F` она возвращается в `ACCEPT`.

**Почему `iptables-save >`, а не `>>`.** Других правил на BR-FW нет, а
дописывание к старому файлу при повторном запуске дало бы в нём дубли.

**Ограничение.** Доверие внутренним сетям построено на адресе источника.
Пакет из интернета с поддельным адресом `192.168.x.x` формально прошёл бы
правило — для учебного стенда это допустимо, в реальной сети такую подмену
режут на пограничном маршрутизаторе (uRPF / `rp_filter`).

## 5. `net_admin`, SSH, время, DNS

* **`net_admin`** с sudo без пароля и **SSH на `2027`**, вход root
  запрещён — как на HQ-RTR и BR-RTR ([03-hq-rtr.md §1.9](03-hq-rtr.md#19-пользователь-net_admin)).
  Нужен, чтобы управлять BR-FW по SSH из филиала и из HQ.
* **Часовой пояс и chrony** — как везде
  ([00-overview.md §4.6–4.7](00-overview.md#46-синхронизация-времени-chrony)),
  сервер времени — `172.16.2.1` (ISP со стороны филиала).
* **DNS** — в самом конце скрипта переключается на HQ-SRV
  (`192.168.100.2`), как на BR-RTR
  ([00-overview.md §4.2](00-overview.md#42-почему-dns-переключается-в-самом-конце-каждого-скрипта)).
  Пока HQ-SRV не настроен, имена на BR-FW не разрешаются; `./retry`
  возвращает `77.88.8.8` перед скачиванием.

## 6. Проверки

Сверх стандартных:

* `Address 192.168.1.2/30 on enp7s1`, `Address 192.168.0.1/28 on enp7s2`;
* `OSPF passive on enp7s2`;
* `BR-RTR responds (192.168.1.1)` и `OSPF route to HQ responds (192.168.100.1)`
  — второй адрес BR-FW может знать только из OSPF;
* `Firewall: INPUT policy DROP`, `Firewall: FORWARD policy DROP`;
* `Firewall: LAN may go out`, `Firewall: SSH/testapp to BR-SRV allowed`,
  `Firewall: OSPF from BR-RTR allowed` — `iptables -C` с теми же правилами;
* `Firewall rules saved for boot` — в `/etc/sysconfig/iptables` есть
  политика `FORWARD DROP`, то есть после перезагрузки экран поднимется тем же.

## 7. NEXT STEP

Команды для BR-SRV: статический `192.168.0.2/28`, шлюз `192.168.0.1` (это
BR-FW), временный DNS `77.88.8.8` на `enp7s1`. VLAN не нужен — сеть
плоская.
