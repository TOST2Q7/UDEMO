#!/bin/bash

hostnamectl set-hostname hq-srv.au-team.irpo

# Установка wget
apt-get update && apt-get install wget
#Настройка ДНС
wget raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/main/dnsmasq.conf
apt-get install -y dnsmasq
systemctl enable --now dnsmasq
rm -rf /etc/dnsmasq.conf
cp -r dnsmasq.conf /etc/
systemctl restart dnsmasq
ping HQ-SRV.au-team.irpo

echo "Настройка SSH"

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


echo "Настройка RAID"
# Создание RAID 0 
mdadm --create --verbose /dev/md0 -l 0 -n 3 /dev/sd[b-d]

# Сохранение конфигурации
mdadm --detail -scan > /etc/mdadm.conf

# Работа с fdisk (автоматический ввод 'n' и 'w')
echo -e "n\n\n\n\n\nw" | fdisk /dev/md0

# Форматирование раздела
mkfs.ext4 /dev/md0p1

# Создание директории и монтирование
mkdir /raid

# Добавление в fstab
echo "/dev/md0p1 /raid ext4 defaults 0 0" >> /etc/fstab
mount -a

# Установка NFS
apt-get install -y nfs-server
systemctl enable --now nfs

# Настройка NFS
mkdir /raid/nfs
chown -R 99:99 /raid/nfs
chmod 777 /raid/nfs

# Добавление экспорта NFS МЕНЯЙТЕ НА СВОИ СЕТИ
echo "/raid/nfs 192.168.200.0/28(rw,sync,no_subtree_check)" >> /etc/exports

# Перезапуск NFS и создание тестового файла
systemctl restart nfs
touch /raid/nfs/test

echo "Готово! RAID 5 и NFS настроены."


echo "- Настройка RESOLV"
# Файл /etc/resolv.conf
cat > /etc/resolv.conf <<EOF
    nameserver 127.0.0.1
    search au-team.irpo

EOF
chattr +i /etc/resolv.conf

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

echo "=== Проверка настроек hq-srv ==="
check "Hostname = hq-srv.au-team.irpo"           '[ "$(hostnamectl --static)" = "hq-srv.au-team.irpo" ]'
check "dnsmasq запущен"                          'systemctl is-active --quiet dnsmasq'
check "dnsmasq в автозапуске"                    'systemctl is-enabled --quiet dnsmasq'
check "/etc/dnsmasq.conf скопирован"             '[ -s /etc/dnsmasq.conf ]'
check "Пользователь sshuser создан (UID 2027)"   '[ "$(id -u sshuser)" = "2027" ]'
check "sshuser состоит в группе wheel"           'id -nG sshuser | grep -qw wheel'
check "sshuser добавлен в sudoers"               'grep -q "sshuser ALL=(ALL) NOPASSWD: ALL" /etc/sudoers'
check "SSH порт изменен на 2027"                 'grep -q "^Port 2027" /etc/openssh/sshd_config'
check "Root-логин по SSH запрещен"               'grep -q "^PermitRootLogin no" /etc/openssh/sshd_config'
check "AllowUsers sshuser настроен"              'grep -q "^AllowUsers sshuser" /etc/openssh/sshd_config'
check "MaxAuthTries 2 настроен"                  'grep -q "^MaxAuthTries 2" /etc/openssh/sshd_config'
check "SSH-баннер создан"                        '[ -f /etc/openssh/banner ]'
check "SSH служба активна"                       'systemctl is-active --quiet sshd'
check "RAID-массив /dev/md0 существует"          'grep -q "^md0 :" /proc/mdstat'
check "/etc/mdadm.conf сохранен"                 '[ -s /etc/mdadm.conf ]'
check "Раздел /raid смонтирован"                 'mountpoint -q /raid'
check "/raid добавлен в fstab"                   'grep -q "/dev/md0p1 /raid" /etc/fstab'
check "NFS-сервер активен"                       'systemctl is-active --quiet nfs'
check "Каталог /raid/nfs существует"             '[ -d /raid/nfs ]'
check "Экспорт NFS настроен"                     'grep -q "^/raid/nfs 192.168.200.0/28" /etc/exports'
check "Тестовый файл NFS создан"                 '[ -f /raid/nfs/test ]'
check "/etc/resolv.conf содержит nameserver 127.0.0.1" 'grep -q "nameserver 127.0.0.1" /etc/resolv.conf'
check "/etc/resolv.conf защищен от изменений (immutable)" 'lsattr /etc/resolv.conf | grep -q "i"'
echo "=== Проверка завершена ==="
