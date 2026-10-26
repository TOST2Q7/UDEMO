#!/bin/bash
# Запускать на BR-SRV после samba.sh: прописывает DNS HQ-SRV (192.168.100.2) на машинах по SSH

# $1 - пользователь@хост, $2 - файлы resolv.conf, $3 - DNS-сервер
set_dns() {
    sshpass -p 'P@ssw0rd' ssh -p 2027 -o StrictHostKeyChecking=no "$1" "sudo tee $2 > /dev/null" <<EOF
search au-team.irpo
nameserver $3
EOF
}

# BR-SRV
set_dns sshuser@192.168.0.2     "/etc/net/ifaces/enp7s1/resolv.conf /etc/resolv.conf" 192.168.100.2
# HQ-SRV (адрес на VLAN enp7s1.100, /etc/resolv.conf уже закреплён на 127.0.0.1 через chattr)
set_dns sshuser@192.168.100.2   "/etc/net/ifaces/enp7s1.100/resolv.conf"              127.0.0.1
# HQ-RTR
set_dns net_admin@192.168.100.1 "/etc/net/ifaces/enp7s1/resolv.conf /etc/resolv.conf" 192.168.100.2
# BR-RTR
set_dns net_admin@192.168.1.1   "/etc/net/ifaces/enp7s1/resolv.conf /etc/resolv.conf" 192.168.100.2

echo "DNS 192.168.100.2 прописан на BR-SRV, HQ-RTR, BR-RTR (HQ-SRV - 127.0.0.1)"
