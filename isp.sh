#!/bin/bash

# Настройка hostname
hostnamectl set-hostname isp.au-team.irpo


# Настрока часового пояса
apt-get update && apt-get install -y chrony tzdata
timedatectl set-timezone Asia/Krasnoyarsk

# Создаем директории для интерфейсов
mkdir -p /etc/net/ifaces/{enp7s2,enp7s3}

# Настраиваем интерфейс enp7s2 (статический IP)
cat <<EOF > /etc/net/ifaces/enp7s2/options
BOOTPROTO=static
TYPE=eth
CONFIG_WIRELESS=no
SYSTEMD_BOOTPROTO=dhcp4
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF

# Настраиваем интерфейс enp7s3 (статический IP)
cat <<EOF > /etc/net/ifaces/enp7s3/options
BOOTPROTO=static
TYPE=eth
CONFIG_WIRELESS=no
SYSTEMD_BOOTPROTO=dhcp4
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF

# Устанавливаем статические адреса для интерфейсов
echo '172.16.1.1/28' > /etc/net/ifaces/enp7s2/ipv4address
echo '172.16.2.1/28' > /etc/net/ifaces/enp7s3/ipv4address

# Настройка маршутизации
sed -i "s/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/" "/etc/net/sysctl.conf"

# Настройка NAT
apt-get install iptables -y
 
iptables -t nat -A POSTROUTING -o enp7s1 -j MASQUERADE
iptables-save > /etc/sysconfig/iptables

# Добавляем IPTABLES в автозапуск
systemctl enable --now iptables

# Перезапускаем сеть
systemctl restart network

# Разрешаем root доступ по SSH
sed -i 's/#*PermitRootLogin.*/PermitRootLogin yes/' /etc/openssh/sshd_config

# Перезапускаем сервис SSHD
systemctl enable --now sshd
systemctl restart sshd.service

apt-get update

echo -e "\033[1;36m=== Next steps \033[30m\033[106mHQ-RTR.sh\033[0m \033[1;36m==="
echo -e "> vim /ifaces/enp7s1/ipv4address < 172.16.1.2/28"
echo -e "> vim /ifaces/enp7s1/ipv4route < default via 172.16.1.1"
echo -e "> vim /ifaces/enp7s1/resolv.conf < nameserver 77.88.8.8"
echo -e "> vim /ifaces/enp7s1/options < BOOTPROTO=static"
echo -e "\033[1;36m=========================================\033[0m"

echo -e "\033[1;36m=== Next steps \033[30m\033[106mBR-RTR.sh\033[0m \033[1;36m==="
echo -e "> vim /ifaces/enp7s1/ipv4address < 172.16.2.2/28"
echo -e "> vim /ifaces/enp7s1/ipv4route < default via 172.16.2.1"
echo -e "> vim /ifaces/enp7s1/resolv.conf < nameserver 77.88.8.8"
echo -e "> vim /ifaces/enp7s1/options < BOOTPROTO=static"
echo -e "\033[1;36m=========================================\033[0m"

exec bash
