#!/bin/bash
# ===========================================================
# Переменные
FILE="./BR-FW.sh"




# ===========================================================

hostnamectl set-hostname br-fw.au-team.irpo

# Настрока часового пояса
apt-get update && apt-get install -y chrony tzdata
timedatectl set-timezone Asia/Krasnoyarsk

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
vtysh << 'EOF'
conf
router ospf
network 192.168.1.0/30 area 0
network 192.168.0.0/28 area 0
exit
do wr
exit
EOF
systemctl restart network
systemctl restart frr

echo "Настройка OSPF завершена!"

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
echo -e "> vim /ifaces/enp7s1/resolv.conf < nameserver 77.88.8.8"
echo -e "> vim /ifaces/enp7s1/options < BOOTPROTO=static"
echo -e "\033[1;36m=========================================\033[0m"

exec bash
