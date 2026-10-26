#!/bin/bash
# ===========================================================
# Переменные
FILE="./BR-FW.sh"

WAN="enp7s1"   # в сторону BR-RTR: интернет и туннель в HQ
LAN="enp7s2"   # сеть BR-SRV
# Внутренние сети (HQ через туннель, туннель, линк BR-RTR) МЕНЯЙТЕ НА СВОИ АДРЕСА
INT_NETS="192.168.100.0/27,192.168.200.0/28,192.168.99.0/29,10.10.10.0/30,192.168.1.0/30"
# ===========================================================

hostnamectl set-hostname br-fw.au-team.irpo

# Настрока часового пояса
apt-get update && apt-get install -y chrony tzdata
timedatectl set-timezone Asia/Krasnoyarsk

# Установка gpasswd
apt-get install -y shadow-groups

# Настройка маршутизации
sed -i "s/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/" "/etc/net/sysctl.conf"

# enp7s1 (192.168.1.2/30 до BR-RTR) настраивается вручную, см. гайд в конце BR-RTR.sh
#Создание enp7s2 (сеть BR-SRV)
mkdir -p /etc/net/ifaces/enp7s2
cp -r /etc/net/ifaces/enp7s1/options /etc/net/ifaces/enp7s2/options
echo "192.168.0.1/28" > /etc/net/ifaces/enp7s2/ipv4address

# Перезапускаем сеть
systemctl restart network


# Установка FRR (если не установлен)
apt-get install -y frr

# Включение OSPF в /etc/frr/daemons (меняем ospfd=no на ospfd=yes)
sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons

# Перезагрузка демона и запуск FRR
systemctl daemon-reload
systemctl enable --now frr

# Настройка OSPF через vtysh (автоматический ввод команд) МЕНЯЙТЕ НА СВОИ АДРЕСА
# В сторону LAN OSPF только объявляет сеть, соседей там не ищет (passive)
vtysh << 'EOF'
conf
router ospf
network 192.168.1.0/30 area 0
network 192.168.0.0/28 area 0
exit
int enp7s2
ip ospf passive
do wr
exit
EOF
systemctl restart network
systemctl restart frr

echo "Настройка OSPF завершена!"

# Межсетевой экран: из интернета во внутреннюю сеть только http, https, dns, ntp, icmp echo
# и проброшенные на BR-RTR порты BR-SRV (2027 - SSH, 8080 - docker). NAT делает BR-RTR.
apt-get install -y iptables
iptables -F INPUT
iptables -F FORWARD

# Сам BR-FW: OSPF от BR-RTR, ping, всё из LAN и внутренних сетей (SSH 2027 и т.д.)
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i $WAN -p 89 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A INPUT -i $LAN -j ACCEPT
iptables -A INPUT -i $WAN -s $INT_NETS -j ACCEPT

# Транзит через BR-FW
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i $LAN -o $WAN -j ACCEPT
iptables -A FORWARD -i $WAN -o $LAN -s $INT_NETS -j ACCEPT
iptables -A FORWARD -i $WAN -o $LAN -p icmp --icmp-type echo-request -j ACCEPT
iptables -A FORWARD -i $WAN -o $LAN -p tcp -m multiport --dports 80,443,53 -j ACCEPT
iptables -A FORWARD -i $WAN -o $LAN -p udp -m multiport --dports 53,123 -j ACCEPT
iptables -A FORWARD -i $WAN -o $LAN -d 192.168.0.2 -p tcp -m multiport --dports 2027,8080 -j ACCEPT

# Остальное запрещаем (политики ставим после правил, чтобы не оборвать связь)
iptables -P INPUT DROP
iptables -P FORWARD DROP

iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables

echo "Межсетевой экран настроен!"

# 1. Создание пользователя net_admin (управление BR-FW по SSH) (ЛИБО ДРУГОГО ПОЛЬЗОВАТЕЛЯ, ПРИ СМЕНЕ ПОМЕНЯТЬ В ЭТОМ ФАЙЛЕ ИМЯ И Т.Д)
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

#Проверка связи с BR-RTR и проверка OSPF
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

check "BR-RTR" 192.168.1.1
# Соседство OSPF на обычном линке поднимается ~40 сек, поэтому ждём до ~60 сек
check "OSPF"   192.168.100.1 20

# Удаляем скрипт
if rm -f "$FILE" 2>/dev/null && [ ! -e "$FILE" ]; then
    echo -e "${GREEN}File deleted: $FILE${NC}"
else
    echo -e "${RED}Cannot delete file: $FILE${NC}"
fi


echo -e "${RED}br-fw.sh finish!${NC}"

echo -e "\033[1;36m=== Next steps \033[30m\033[106mBR-SRV.sh\033[0m \033[1;36m==="
echo -e "> vim /ifaces/enp7s1/ipv4address < 192.168.0.2/28"
echo -e "> vim /ifaces/enp7s1/ipv4route < default via 192.168.0.1"
echo -e "> vim /ifaces/enp7s1/resolv.conf < "
echo -e "nameserver 77.88.8.8"
echo -e "nameserver 192.168.100.2"
echo -e "search au-team.irpo"
echo -e "> vim /ifaces/enp7s1/options < BOOTPROTO=static"
echo -e "\033[1;36m=========================================\033[0m"

exec bash
