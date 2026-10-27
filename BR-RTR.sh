#!/bin/bash
# ===========================================================
# Переменные
FILE="./BR-RTR.sh"




# ===========================================================

hostnamectl set-hostname br-rtr.au-team.irpo

# Настрока часового пояса
apt-get update && apt-get install -y chrony tzdata sshpass
timedatectl set-timezone Asia/Krasnoyarsk

# Установка gpasswd
apt-get install -y shadow-groups

# Настройка маршутизации
sed -i "s/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/" "/etc/net/sysctl.conf"

#Создание enp7s2 (линк до BR-FW, сеть BR-SRV 192.168.0.0/28 теперь за BR-FW)
mkdir -p /etc/net/ifaces/enp7s2
cp -r /etc/net/ifaces/enp7s1/options /etc/net/ifaces/enp7s2/options
echo "192.168.1.1/30" > /etc/net/ifaces/enp7s2/ipv4address


# Создаем директорию и файлы конфигурации
mkdir -p /etc/net/ifaces/tun0

# Файл options
cat > /etc/net/ifaces/tun0/options <<EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.2.2
TUNREMOTE=172.16.1.2
TUNTTL=64
TUNOPTIONS='ttl 64'
HOST=enp7s1
EOF

# Файл ipv4address
echo "10.10.10.2/30" > /etc/net/ifaces/tun0/ipv4address

# Загружаем модуль GRE и перезапускаем сеть
modprobe gre
systemctl restart network

echo "Туннель настроен"


# Установка FRR (если не установлен)
apt-get install -y frr

# Включение OSPF в /etc/frr/daemons (меняем ospfd=no на ospfd=yes)
sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons

# Перезагрузка демона и запуск FRR
systemctl daemon-reload
systemctl enable --now frr

# Настройка OSPF через vtysh (автоматический ввод команд) МЕНЯЙТЕ НА СВОИ АДРЕСА
vtysh << 'EOF'
conf
router ospf
network 192.168.1.0/30 area 0
network 10.10.10.0/30 area 0
exit
int tun0
ip ospf authentication message-digest
ip ospf message-digest-key 1 md5 P@ssw0rd
ip ospf network broadcast
do wr
exit
EOF
systemctl restart network
systemctl restart frr

echo "Настройка OSPF завершена!"

#ставим NAT и проброс портов (8080 -> BR-SRV:8080, 2027 -> BR-SRV:2027)
apt-get install iptables -y
iptables -t nat -A POSTROUTING -o enp7s1 -j MASQUERADE
iptables -t nat -A PREROUTING -i enp7s1 -p tcp --dport 8080 -j DNAT --to-destination 192.168.0.2:8080
iptables -t nat -A PREROUTING -i enp7s1 -p tcp --dport 2027 -j DNAT --to-destination 192.168.0.2:2027
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
systemctl enable --now sshd
systemctl restart sshd

echo "Готово! Пользователь net_admin создан, SSH настроен на порт 2027."

# DNS: HQ-SRV вместо 77.88.8.8, вписанного вручную (в конце: интернет скрипту больше не нужен)
cat > /etc/net/ifaces/enp7s1/resolv.conf <<EOF
nameserver 192.168.100.2
search au-team.irpo
EOF
cp /etc/net/ifaces/enp7s1/resolv.conf /etc/resolv.conf

#Проверка туннеля и проверка OSPF
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# $3 - число попыток (по умолчанию 1)
check() {
    for i in $(seq 1 "${3:-1}"); do
        if ping -c 3 -W 1 "$2" &> /dev/null; then
            echo -e "${GREEN}$1: OK${NC}"
            return
        fi
    done
    echo -e "${RED}$1: FAIL${NC}"
}

check "Tunnel" 10.10.10.1
# tun0 в режиме broadcast: соседство OSPF поднимается ~40 сек, поэтому ждём до ~60 сек
check "OSPF"   192.168.100.1 20

# Удаляем скрипт
if rm -f "$FILE" 2>/dev/null && [ ! -e "$FILE" ]; then
    echo -e "${GREEN}File deleted: $FILE${NC}"
else
    echo -e "${RED}Cannot delete file: $FILE${NC}"
fi


echo -e "${RED}br-rtr.sh finish!${NC}"

echo -e "\033[1;36m=== Next steps \033[30m\033[106mBR-FW.sh\033[0m \033[1;36m==="
echo -e "> vim /ifaces/enp7s1/ipv4address < 192.168.1.2/30"
echo -e "> vim /ifaces/enp7s1/ipv4route < default via 192.168.1.1"
echo -e "> vim /ifaces/enp7s1/resolv.conf < nameserver 77.88.8.8"
echo -e "> vim /ifaces/enp7s1/options < BOOTPROTO=static"
echo -e "\033[1;36m=========================================\033[0m"

exec bash
