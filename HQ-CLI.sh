#!/bin/bash
apt-get update && apt-get install -y yandex-browser-stable

hostnamectl set-hostname hq-cli.au-team.irpo

# Монтирование RAID 
mkdir /mnt/nfs

# Файл options
cat >> /etc/fstab <<EOF
192.168.100.2:/raid/nfs /mnt/nfs nfs rw 0 0
EOF
mount -a
ls /mnt/nfs

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

echo "=== Проверка настроек hq-cli ==="
check "Hostname = hq-cli.au-team.irpo"           '[ "$(hostnamectl --static)" = "hq-cli.au-team.irpo" ]'
check "Yandex Browser установлен"                'rpm -q yandex-browser-stable'
check "/mnt/nfs смонтирован"                     'mountpoint -q /mnt/nfs'
check "NFS-точка добавлена в fstab"              'grep -q "192.168.100.2:/raid/nfs /mnt/nfs nfs" /etc/fstab'
check "Пользователь sshuser создан (UID 2027)"   '[ "$(id -u sshuser)" = "2027" ]'
check "sshuser состоит в группе wheel"           'id -nG sshuser | grep -qw wheel'
check "sshuser добавлен в sudoers"               'grep -q "sshuser ALL=(ALL) NOPASSWD: ALL" /etc/sudoers'
check "SSH порт изменен на 2027"                 'grep -q "^Port 2027" /etc/openssh/sshd_config'
check "Root-логин по SSH запрещен"               'grep -q "^PermitRootLogin no" /etc/openssh/sshd_config'
check "AllowUsers sshuser настроен"              'grep -q "^AllowUsers sshuser" /etc/openssh/sshd_config'
check "MaxAuthTries 2 настроен"                  'grep -q "^MaxAuthTries 2" /etc/openssh/sshd_config'
check "SSH-баннер создан"                        '[ -f /etc/openssh/banner ]'
check "SSH служба активна"                       'systemctl is-active --quiet sshd'
echo "=== Проверка завершена ==="

