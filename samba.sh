apt-get update

apt-get install -y task-samba-dc

for service in smb nmb krb5kdc slapd bind;
do
  systemctl disable $service --now;
done

rm -f /etc/samba/smb.conf

rm -f /etc/cache/smb.conf

rm -rf /var/lib/samba 
rm -rf /var/cache/samba

mkdir -p /var/lib/samba/sysvol

samba-tool domain provision \
  --realm="AU-TEAM.IRPO" \
  --domain="AU-TEAM" \
  --server-role="dc" \
  --dns-backend="SAMBA_INTERNAL" \
  --option="dns forwarder=192.168.100.2" \
  --adminpass="P@ssw0rd" 

systemctl enable --now samba

/bin/cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf

systemctl restart samba

cat > "/etc/net/ifaces/enp7s1/resolv.conf" <<EOF
search au-team.irpo
nameserver 127.0.0.1
EOF

systemctl restart network

echo "P@ssw0rd" | kinit Administrator@AU-TEAM.IRPO

samba-tool group add hq

for i in {1..5};
do
  samba-tool user add hquser$i P@ssw0rd;
  samba-tool user setexpiry hquser$i --noexpiry;
  samba-tool group addmembers "hq" hquser$i;
done

cat > /etc/chrony.conf <<EOF
server 172.16.2.1 iburst
EOF

systemctl restart chronyd

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

echo "=== Проверка настроек samba-dc ==="
check "Samba служба активна"                     'systemctl is-active --quiet samba'
check "Samba служба в автозапуске"               'systemctl is-enabled --quiet samba'
check "Домен AU-TEAM.IRPO создан"                'samba-tool domain info 127.0.0.1'
check "/etc/krb5.conf скопирован"                '[ -s /etc/krb5.conf ]'
check "resolv.conf enp7s1 настроен (search au-team.irpo)" 'grep -q "search au-team.irpo" /etc/net/ifaces/enp7s1/resolv.conf'
check "Группа hq создана"                        'samba-tool group list | grep -qw hq'
for i in 1 2 3 4 5; do
    check "Пользователь hquser$i создан"         "samba-tool user list | grep -qw hquser$i"
done
check "chronyd активен"                          'systemctl is-active --quiet chronyd'
check "chrony.conf указывает на 172.16.2.1"      'grep -q "^server 172.16.2.1 iburst" /etc/chrony.conf'
echo "=== Проверка завершена ==="

