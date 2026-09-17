#!/bin/bash

sed -i 's/^dhcp-option=6,77\.88\.8\.8$/dhcp-option=6,192.168.100.2/' /etc/dnsmasq.conf

echo "Change 77.88.8.8 to 192.168.100.2"

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

echo "=== Проверка настроек HQ-RTR-2 ==="
check "dhcp-option=6 указывает на 192.168.100.2"    'grep -q "^dhcp-option=6,192.168.100.2$" /etc/dnsmasq.conf'
check "Старое значение 77.88.8.8 больше не задано"  '! grep -q "^dhcp-option=6,77.88.8.8$" /etc/dnsmasq.conf'
check "dnsmasq запущен"                             'systemctl is-active --quiet dnsmasq'
echo "=== Проверка завершена ==="