#!/bin/bash
# ===========================================================
# Переменные
FILE="./HQ-RTR.sh"






# ===========================================================

hostnamectl set-hostname hq-rtr.au-team.irpo

# Установка gpasswd
apt-get install shadow-groups -y

#Создание enp7s2
mkdir -p /etc/net/ifaces/enp7s2
cp -r /etc/net/ifaces/enp7s1/options /etc/net/ifaces/enp7s2/options

# Создание VLAN 100
mkdir -p /etc/net/ifaces/enp7s2.100/
cat > /etc/net/ifaces/enp7s2.100/options <<EOF
TYPE=vlan
HOST=enp7s2
VID=100
BOOTPROTO=static
EOF

# Создание VLAN 200
mkdir -p /etc/net/ifaces/enp7s2.200/
cat > /etc/net/ifaces/enp7s2.200/options <<EOF
TYPE=vlan
HOST=enp7s2
VID=200
BOOTPROTO=static
EOF

# Создание VLAN999
mkdir -p /etc/net/ifaces/enp7s2.999/
cat > /etc/net/ifaces/enp7s2.999/options <<EOF
TYPE=vlan
HOST=enp7s2
VID=999
BOOTPROTO=static
EOF
echo "192.168.100.1/27" > /etc/net/ifaces/enp7s2.100/ipv4address
echo "192.168.200.1/28" > /etc/net/ifaces/enp7s2.200/ipv4address
echo "192.168.99.1/29" > /etc/net/ifaces/enp7s2.999/ipv4address

# Настройка маршутизации
sed -i "s/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/" "/etc/net/sysctl.conf"

# Перезапуск сети
systemctl restart network

# Установка и настройка dnsmasq
apt-get update && apt-get install -y dnsmasq
cat > /etc/dnsmasq.conf <<EOF
no-resolv
domain=au-team.irpo
dhcp-range=192.168.200.2,192.168.200.10,999h
dhcp-option=3,192.168.200.1
dhcp-option=6,77.88.8.8
dhcp-option=15,au-team.irpo
interface=enp7s2.200
EOF

# Включение и запуск dnsmasq
systemctl enable --now dnsmasq
systemctl restart dnsmasq

# Создаем директорию и файлы конфигурации
mkdir -p /etc/net/ifaces/tun0

# Файл options
cat > /etc/net/ifaces/tun0/options <<EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.1.2
TUNREMOTE=172.16.2.2
TUNTTL=64
TUNOPTIONS='ttl 64'
HOST=enp7s1
EOF

# Файл ipv4address
echo "10.10.10.1/30" > /etc/net/ifaces/tun0/ipv4address

# Загружаем модуль GRE и перезапускаем сеть
modprobe gre
systemctl restart network

echo "Туннель настроен"





# Установка FRR (если не установлен)
apt-get install frr -y

# Включение OSPF в /etc/frr/daemons (меняем ospfd=no на ospfd=yes)
sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons

# Перезагрузка демона и запуск FRR
systemctl daemon-reload
systemctl enable --now frr

# Настройка OSPF через vtysh (автоматический ввод команд) МЕНЯЙТЕ НА СВОИ АДРЕСА
vtysh << 'EOF'
conf
router ospf
network 192.168.100.0/27 area 0
network 192.168.200.0/28 area 0
network 192.168.99.0/29 area 0
network 10.10.10.0/30 area 0
exit
int tun0
ip ospf authentication message-digest
ip ospf message-digest-key 1 md5 P@ssw0rd
do wr
exit
EOF

echo "Настройка OSPF завершена!"

#ставим NAT 
apt-get install iptables -y
iptables -t nat -A POSTROUTING -o enp7s1 -j MASQUERADE 
#iptables -t nat -A PREROUTING -p tcp -d 192.168.100.1 --dport 2027 -j DNAT --to-destination 192.168.100.2:2027
iptables-save >> /etc/sysconfig/iptables
systemctl enable --now iptables

# 1. Создание пользователя net_admin (ЛИБО ДРУГОГО ПОЛЬЗОВАТЕЛЯ, ПРИ СМЕНЕ ПОМЕНЯТЬ В ЭТОМ ФАЙЛЕ ИМЯ И Т.Д)
useradd -m net_admin

# 2. Установка пароля P@$$word (без подтверждения)
echo "net_admin:P@ssw0rd" | chpasswd

# 3. Добавление в группу wheel
gpasswd -a net_admin wheel

# 4. Настройка sudo без пароля
echo "net_admin ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# 5. Настройка SSH (порт 2027 и запрет root-логина)
sed -i 's/#Port 22/Port 2027/' /etc/openssh/sshd_config
sed -i 's/#PermitRootLogin without-password/PermitRootLogin no/' /etc/openssh/sshd_config

# 6. Перезапуск SSH
systemctl restart sshd

# ===========================================================
# Итоговая проверка того, что настроил этот скрипт
# ===========================================================
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

check() {
    local desc="$1"; shift
    if eval "$*" &>/dev/null; then
        echo -e "${GREEN}[OK]${NC} $desc"
    else
        echo -e "${RED}[FAIL]${NC} $desc"
    fi
}

echo "=== Проверка настроек hq-rtr ==="
check "Hostname = hq-rtr.au-team.irpo"              '[ "$(hostnamectl --static)" = "hq-rtr.au-team.irpo" ]'
check "IP forwarding включен"                       'grep -q "net.ipv4.ip_forward = 1" /etc/net/sysctl.conf'
check "VLAN100 (enp7s2.100) поднят"                 'ip addr show enp7s2.100'
check "Адрес 192.168.100.1/27 на enp7s2.100"        'ip -4 addr show enp7s2.100 | grep -q "192.168.100.1/27"'
check "VLAN200 (enp7s2.200) поднят"                 'ip addr show enp7s2.200'
check "Адрес 192.168.200.1/28 на enp7s2.200"        'ip -4 addr show enp7s2.200 | grep -q "192.168.200.1/28"'
check "VLAN999 (enp7s2.999) поднят"                 'ip addr show enp7s2.999'
check "Адрес 192.168.99.1/29 на enp7s2.999"         'ip -4 addr show enp7s2.999 | grep -q "192.168.99.1/29"'
check "dnsmasq запущен"                             'systemctl is-active --quiet dnsmasq'
check "dnsmasq в автозапуске"                       'systemctl is-enabled --quiet dnsmasq'
check "dnsmasq слушает VLAN200"                     'grep -q "^interface=enp7s2.200$" /etc/dnsmasq.conf'
check "Интерфейс tun0 (GRE) поднят"                 'ip addr show tun0'
check "Адрес 10.10.10.1/30 на tun0"                 'ip -4 addr show tun0 | grep -q "10.10.10.1/30"'
check "FRR запущен"                                 'systemctl is-active --quiet frr'
check "OSPF демон включен в FRR"                    'grep -q "ospfd=yes" /etc/frr/daemons'
check "Туннель до филиала отвечает (10.10.10.2)"    'ping -c 3 -W 1 10.10.10.2'
check "Сервер HQ-SRV доступен (192.168.100.2)"      'ping -c 3 -W 1 192.168.100.2'
check "NAT MASQUERADE настроен"                     'iptables -t nat -C POSTROUTING -o enp7s1 -j MASQUERADE'
check "iptables в автозапуске"                      'systemctl is-enabled --quiet iptables'
check "Пользователь net_admin создан"               'id net_admin'
check "net_admin состоит в группе wheel"            'id -nG net_admin | grep -qw wheel'
check "net_admin добавлен в sudoers"                'grep -q "net_admin ALL=(ALL) NOPASSWD: ALL" /etc/sudoers'
check "SSH порт изменен на 2027"                    'grep -q "^Port 2027" /etc/openssh/sshd_config'
check "Root-логин по SSH запрещен"                  'grep -q "^PermitRootLogin no" /etc/openssh/sshd_config'
check "SSH служба активна"                          'systemctl is-active --quiet sshd'
echo "=== Проверка завершена ==="

# Удаляем скрипт
if rm -f "$FILE" 2>/dev/null && [ ! -e "$FILE" ]; then
    echo -e "${GREEN}File deleted: $FILE${NC}"
else
    echo -e "${RED}Cannot delete file: $FILE${NC}"
fi


echo "Готово! Пользователь net_admin создан, SSH настроен на порт 2027."

echo -e "\033[1;36m=== Next steps \033[30m\033[106mHQ-SRV.sh\033[0m \033[1;36m==="
echo -e "> mkdir /etc/net/ifaces/enp7s1.100/"
echo -e "> vim /ifaces/enp7s1.100/ipv4address < 192.168.100.2/27"
echo -e "> vim /ifaces/enp7s1.100/ipv4route < 192.168.100.1"
echo -e "> vim /ifaces/enp7s1.100/resolv.conf < nameserver 77.88.8.8"
echo -e "> vim /ifaces/enp7s1.100/options < "
echo -e "TYPE=vlan"
echo -e "VID=100"
echo -e "BOOTPROTO=static"
echo -e "HOST=enp7s1"
echo -e "\033[1;36m=========================================\033[0m"

exec bash
