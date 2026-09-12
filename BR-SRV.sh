#!/bin/bash
echo "Настройка SSH"

hostnamectl set-hostname br-srv.au-team.irpo

# Создание пользователя sshuser с UID 2027 (МЕНЯЙТЕ ИМЯ И Т.Д В ЗАВИСИМОСТИ ОТ ЗАДАНИЯ)
useradd -u 2027 -m sshuser

# Установка пароля P@ssw0rd без подтверждения
echo "sshuser:P@ssw0rd" | chpasswd

# Добавление в группу wheel
gpasswd -a sshuser wheel

# Настройка sudo без пароля
echo "sshuser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Настройка SSH
sed -i 's/#Port 22/Port 2027/' /etc/openssh/sshd_config
sed -i 's/#PermitRootLogin without-password/PermitRootLogin no/' /etc/openssh/sshd_config
echo "AllowUsers sshuser" >> /etc/openssh/sshd_config
echo "MaxAuthTries 2" >> /etc/openssh/sshd_config
echo "Banner /etc/openssh/banner" >> /etc/openssh/sshd_config

# Создание баннера
echo "Authorized access only" > /etc/openssh/banner

# Перезапуск SSH
systemctl restart sshd

echo "Настройка завершена:"
echo "- Пользователь: sshuser (пароль: P@ssw0rd)"
echo "- SSH порт: 2027"
echo "- Root-логин запрещен"
echo "- Баннер создан"


echo "- Скачиваем файл инвентаря"
apt-get update && apt-get install -y ansible sshpass 
cd /etc/ansible
wget raw.githubusercontent.com/19zammik86-source/DEMO/refs/heads/main/inventory.yml



# Пропинговка shh для работы ansible
apt-get install sshpass -y

sshpass -p 'P@ssw0rd' ssh -p 2027 net_admin@172.16.2.2
sshpass -p 'P@ssw0rd' ssh -p 2027 net_admin@172.16.1.2
sshpass -p 'P@ssw0rd' ssh -p 2027 sshuser@192.168.100.2
sshpass -p 'P@ssw0rd' ssh -p 2027 sshuser@192.168.0.2

# --- Подключение к хосту с динамическим IP (DHCP-пул 192.168.200.2-192.168.200.10) ---
PORT=2027
USER=sshuser
SUBNET=192.168.200
TIMEOUT=1
FOUND_IP=""

for i in $(seq 2 10); do
    IP="${SUBNET}.${i}"
    if nc -z -w "$TIMEOUT" "$IP" "$PORT" 2>/dev/null; then
        FOUND_IP="$IP"
        break
    fi
done

if [ -n "$FOUND_IP" ]; then
    echo "Host was found: $FOUND_IP"
    exec sshpass -p 'P@ssw0rd' ssh -p "$PORT" "${USER}@${FOUND_IP}"
else
    echo "Net ego ${SUBNET}.2-10 na  porty ${PORT}" >&2
    exit 1
fi

