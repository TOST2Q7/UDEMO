#!/bin/bash

# Настройка hostname
hostnamectl set-hostname isp.au-team.irpo


# Настрока часового пояса
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

echo "=== Проверка настроек isp ==="
check "Hostname = isp.au-team.irpo"          '[ "$(hostnamectl --static)" = "isp.au-team.irpo" ]'
check "Часовой пояс Asia/Krasnoyarsk"        '[ "$(timedatectl show -p Timezone --value)" = "Asia/Krasnoyarsk" ]'
check "Интерфейс enp7s2 поднят"              'ip addr show enp7s2'
check "Адрес 172.16.1.1/28 на enp7s2"        'ip -4 addr show enp7s2 | grep -q "172.16.1.1/28"'
check "Интерфейс enp7s3 поднят"              'ip addr show enp7s3'
check "Адрес 172.16.2.1/28 на enp7s3"        'ip -4 addr show enp7s3 | grep -q "172.16.2.1/28"'
check "IP forwarding включен"                'grep -q "net.ipv4.ip_forward = 1" /etc/net/sysctl.conf'
check "NAT MASQUERADE настроен"              'iptables -t nat -C POSTROUTING -o enp7s1 -j MASQUERADE'
check "iptables в автозапуске"               'systemctl is-enabled --quiet iptables'
check "Root-логин по SSH разрешен"           'grep -q "^PermitRootLogin yes" /etc/openssh/sshd_config'
check "SSH служба активна"                   'systemctl is-active --quiet sshd'
echo "=== Проверка завершена ==="

exec bash
