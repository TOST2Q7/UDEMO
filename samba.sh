#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/checks/$NAME"
# ===========================================================

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
# Point DNS at HQ-SRV - done last, everything above still needs
# the public resolver
# ===========================================================
cat > /etc/net/ifaces/enp7s1/resolv.conf <<EOF
nameserver 192.168.100.2
search au-team.irpo
EOF
cp /etc/net/ifaces/enp7s1/resolv.conf /etc/resolv.conf

# ===========================================================
# Final check of everything this script configured
# ===========================================================
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[1;36m'
NC='\033[0m'

check() {
    local desc="$1"; shift
    local result
    if eval "$*" &>/dev/null; then
        result="[OK] $desc"
        echo -e "${GREEN}${result}${NC}"
    else
        result="[FAIL] $desc"
        echo -e "${RED}${result}${NC}"
    fi
    echo "$result" >> "$LOG"
}

: > "$LOG"
echo "=== Checking samba-dc configuration ===" | tee -a "$LOG"
check "Samba service active"                        'systemctl is-active --quiet samba'
check "Samba service enabled at boot"               'systemctl is-enabled --quiet samba'
check "Domain AU-TEAM.IRPO created"                 'samba-tool domain info 127.0.0.1'
check "/etc/krb5.conf copied"                       '[ -s /etc/krb5.conf ]'
check "Group hq created"                            'samba-tool group list | grep -qw hq'
for i in 1 2 3 4 5; do
    check "User hquser$i created"                   "samba-tool user list | grep -qw hquser$i"
done
check "chronyd active"                              'systemctl is-active --quiet chronyd'
check "chrony.conf points to 172.16.2.1"            'grep -q "^server 172.16.2.1 iburst" /etc/chrony.conf'
check "DNS on enp7s1: 192.168.100.2, search au-team.irpo" 'grep -qx "nameserver 192.168.100.2" /etc/net/ifaces/enp7s1/resolv.conf && grep -qx "search au-team.irpo" /etc/net/ifaces/enp7s1/resolv.conf'
echo "=== Check complete, log saved to $LOG ===" | tee -a "$LOG"

# ===========================================================
# Create retry/delete helper files, then remove this script
# ===========================================================
cat > "$DIR/retry" <<RETRYEOF
#!/bin/bash
wget -O "$SELF" "$RAW_URL"
chmod +x "$SELF"
exec "$SELF"
RETRYEOF
chmod +x "$DIR/retry"

cat > "$DIR/delete" <<DELEOF
#!/bin/bash
# Removes everything created by $NAME in this directory
rm -f "$LOG" "$DIR/retry" "$DIR/delete" "$SELF"
DELEOF
chmod +x "$DIR/delete"

rm -f "$SELF"

echo
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} NEXT STEP${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e " Domain controller deployment complete."
echo -e " Nothing else to configure on this host."
echo -e " (Requires HQ-SRV.sh to already be running for DNS forwarding.)"
echo -e "${CYAN}============================================================${NC}"
echo
