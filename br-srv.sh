#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/checks/$NAME"
# ===========================================================

echo "Configuring SSH"

hostnamectl set-hostname br-srv.au-team.irpo

# Create user sshuser with UID 2027 (CHANGE NAME ETC DEPENDING ON THE TASK)
useradd -u 2027 -m sshuser

# Set password P@ssw0rd (no confirmation)
echo "sshuser:P@ssw0rd" | chpasswd

# Add to group wheel
gpasswd -a sshuser wheel

# Configure passwordless sudo
echo "sshuser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Configure SSH
sed -i 's/#Port 22/Port 2027/' /etc/openssh/sshd_config
sed -i 's/#PermitRootLogin without-password/PermitRootLogin no/' /etc/openssh/sshd_config
echo "AllowUsers sshuser" >> /etc/openssh/sshd_config
echo "MaxAuthTries 2" >> /etc/openssh/sshd_config
echo "Banner /etc/openssh/banner" >> /etc/openssh/sshd_config

# Create banner
echo "Authorized access only" > /etc/openssh/banner

# Restart SSH
systemctl restart sshd

echo "Configuration complete:"
echo "- User: sshuser (password: P@ssw0rd)"
echo "- SSH port: 2027"
echo "- Root login disabled"
echo "- Banner created"

# ===========================================================
# Check hostname/user/SSH configuration
# ===========================================================
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
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
echo "=== Checking br-srv configuration ===" | tee -a "$LOG"
check "Hostname = br-srv.au-team.irpo"              '[ "$(hostnamectl --static)" = "br-srv.au-team.irpo" ]'
check "User sshuser created (UID 2027)"             '[ "$(id -u sshuser)" = "2027" ]'
check "sshuser is in group wheel"                   'id -nG sshuser | grep -qw wheel'
check "sshuser added to sudoers"                    'grep -q "sshuser ALL=(ALL) NOPASSWD: ALL" /etc/sudoers'
check "SSH port changed to 2027"                    'grep -q "^Port 2027" /etc/openssh/sshd_config'
check "SSH root login disabled"                     'grep -q "^PermitRootLogin no" /etc/openssh/sshd_config'
check "AllowUsers sshuser configured"               'grep -q "^AllowUsers sshuser" /etc/openssh/sshd_config'
check "MaxAuthTries 2 configured"                   'grep -q "^MaxAuthTries 2" /etc/openssh/sshd_config'
check "SSH banner created"                          '[ -f /etc/openssh/banner ]'
check "SSH service active"                          'systemctl is-active --quiet sshd'

echo "- Downloading inventory file"
apt-get update && apt-get install -y ansible sshpass
mkdir -p /etc/ansible
cd /etc/ansible
wget raw.githubusercontent.com/19zammik86-source/DEMO/refs/heads/main/inventory.yml

cat > /etc/ansible/ansible.cfg <<EOF
[defaults]
interpreter_python = /usr/bin/python3
inventory = /etc/ansible/inventory.yml
host_key_checking = false
EOF

# ===========================================================
# NTP client: sync time from the chrony server on ISP
# ===========================================================
apt-get install -y chrony
cat > /etc/chrony.conf <<EOF
server 172.16.2.1 iburst
EOF
systemctl enable --now chronyd
systemctl restart chronyd
# Give the first sync up to ~30 s so the check below sees it
chronyc waitsync 15 0 0 2 >/dev/null

# ===========================================================
# Point DNS at HQ-SRV - done after the last download, which still
# needs the public resolver
# ===========================================================
cat > /etc/net/ifaces/enp7s1/resolv.conf <<EOF
nameserver 192.168.100.2
search au-team.irpo
EOF
cp /etc/net/ifaces/enp7s1/resolv.conf /etc/resolv.conf

check "DNS on enp7s1: 192.168.100.2, search au-team.irpo" 'grep -qx "nameserver 192.168.100.2" /etc/net/ifaces/enp7s1/resolv.conf && grep -qx "search au-team.irpo" /etc/net/ifaces/enp7s1/resolv.conf'
check "ansible installed"                           'command -v ansible'
check "sshpass installed"                           'command -v sshpass'
check "inventory.yml downloaded"                    '[ -s /etc/ansible/inventory.yml ]'
check "ansible.cfg configured"                      'grep -qx "inventory = /etc/ansible/inventory.yml" /etc/ansible/ansible.cfg && grep -qx "host_key_checking = false" /etc/ansible/ansible.cfg'
check "chronyd active"                              'systemctl is-active --quiet chronyd'
check "chronyd enabled at boot"                     'systemctl is-enabled --quiet chronyd'
check "chrony.conf points to ISP (172.16.2.1)"     'grep -qx "server 172.16.2.1 iburst" /etc/chrony.conf'
check "Time synced from ISP (172.16.2.1)"          'chronyc -n sources | grep -q "^\^\* 172.16.2.1 "'
echo "=== Check complete, log saved to $LOG ===" | tee -a "$LOG"

echo
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} NEXT STEP${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e " Next on this host: ${YELLOW}samba.sh${NC} - the domain controller for au-team.irpo."
echo -e " Then, also on this host: ${YELLOW}docker.sh${NC} (testapp + MariaDB from the exam ISO)."
echo -e " Use /etc/ansible/inventory.yml here to manage the lab with Ansible."
echo -e "${CYAN}============================================================${NC}"
echo

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

# Ping SSH so ansible can work
apt-get install sshpass -y

sshpass -p 'P@ssw0rd' ssh -p 2027 net_admin@192.168.100.1
sshpass -p 'P@ssw0rd' ssh -p 2027 net_admin@192.168.0.1
sshpass -p 'P@ssw0rd' ssh -p 2027 sshuser@192.168.100.2
sshpass -p 'P@ssw0rd' ssh -p 2027 sshuser@192.168.0.2

# --- Connect to the host with a dynamic IP (DHCP pool 192.168.200.2-192.168.200.10) ---
PORT=2027
USER=sshuser
SUBNET=192.168.200
TIMEOUT=3
FOUND_IP=""

# bash's /dev/tcp instead of nc, which Alt does not ship by default;
# ping first so a dead address costs 1 s instead of a hanging connect
for i in $(seq 2 10); do
    IP="${SUBNET}.${i}"
    ping -c 1 -W 1 "$IP" &>/dev/null || continue
    if timeout "$TIMEOUT" bash -c "</dev/tcp/$IP/$PORT" 2>/dev/null; then
        FOUND_IP="$IP"
        break
    fi
done

if [ -n "$FOUND_IP" ]; then
    echo "Host was found: $FOUND_IP"
    # inventory.yml ships a fixed HQ-CLI address, but HQ-CLI gets a random one from DHCP
    sed -i "/^ *hq-cli:/,/ansible_host:/ s/ansible_host: .*/ansible_host: $FOUND_IP/" /etc/ansible/inventory.yml
else
    echo "No host found on ${SUBNET}.2-10 port ${PORT} - hq-cli keeps its inventory address" >&2
fi

ansible -m ping all

[ -n "$FOUND_IP" ] && sshpass -p 'P@ssw0rd' ssh -p "$PORT" "${USER}@${FOUND_IP}"

exec bash
