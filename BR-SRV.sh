#!/bin/bash
hostnamectl set-hostname br-srv.au-team.irpo

# Настрока часового пояса
apt-get update && apt-get install -y chrony tzdata sshpass
timedatectl set-timezone Asia/Krasnoyarsk
systemctl enable --now chronyd
systemctl restart chronyd

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


# HQ-RTR, BR-RTR, HQ-SRV и HQ-CLI к этому моменту уже должны быть настроены
echo "- Настройка Ansible"
apt-get update && apt-get install -y ansible sshpass

# ansible.cfg: без проверки ключей, python3, свой inventory (без дублей при повторном запуске)
CFG=/etc/ansible/ansible.cfg
mkdir -p /etc/ansible
grep -q '^\[defaults\]' "$CFG" 2>/dev/null || echo '[defaults]' >> "$CFG"
grep -q '^host_key_checking' "$CFG" || sed -i '/^\[defaults\]/a host_key_checking = false' "$CFG"
grep -q '^interpreter_python' "$CFG" || sed -i '/^\[defaults\]/a interpreter_python = /usr/bin/python3' "$CFG"
grep -q '^inventory' "$CFG" || sed -i '/^\[defaults\]/a inventory = /etc/ansible/inventory.yml' "$CFG"

echo "- Скачиваем файл инвентаря и плейбук"
cd /etc/ansible
wget -O inventory.yml raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/main/inventory2.yml
wget -O get_hostname.yml raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/main/get_hostname.yml

# --- Поиск HQ-CLI с динамическим IP (DHCP-пул 192.168.200.2-192.168.200.10) ---
PORT=2027
SUBNET=192.168.200
TIMEOUT=1
FOUND_IP=""

for i in $(seq 2 10); do
    IP="${SUBNET}.${i}"
    if timeout "$TIMEOUT" bash -c "</dev/tcp/$IP/$PORT" 2>/dev/null; then
        FOUND_IP="$IP"
        break
    fi
done

if [ -n "$FOUND_IP" ]; then
    echo "Host was found: $FOUND_IP"
    # Подставляем найденный адрес HQ-CLI в inventory
    sed -i "/hq-cli:/{n;s/ansible_host: .*/ansible_host: $FOUND_IP/}" inventory.yml
else
    echo "Net ego ${SUBNET}.2-10 na  porty ${PORT}, v inventory ostalsya adres po umolchaniyu" >&2
fi

# Первое подключение по SSH ко всем хостам (принимаем ключи)
SSH="sshpass -p P@ssw0rd ssh -p 2027 -o StrictHostKeyChecking=no -o ConnectTimeout=5"
$SSH sshuser@192.168.0.2 exit
$SSH sshuser@192.168.100.2 exit
[ -n "$FOUND_IP" ] && $SSH sshuser@"$FOUND_IP" exit
$SSH net_admin@192.168.100.1 exit
$SSH net_admin@192.168.1.1 exit

ansible -m ping all
ansible-playbook /etc/ansible/get_hostname.yml
ls /etc/ansible/PC_INFO
