#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
# NEXT STEP banner is also saved here: cat it to see the steps again
NEXT="$DIR/${NAME%.sh}-next-step.txt"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/checks/$NAME"
# ===========================================================

echo "Configuring SSH"

hostnamectl set-hostname br-srv.tkhis.pro

# Create user userssh with UID 2027 (CHANGE NAME ETC DEPENDING ON THE TASK)
useradd -u 2027 -m userssh

# Set password P@ssw0rd (no confirmation)
echo "userssh:P@ssw0rd" | chpasswd

# Add to group wheel
gpasswd -a userssh wheel

# Configure passwordless sudo
echo "userssh ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Configure SSH
sed -i 's/#Port 22/Port 2127/' /etc/openssh/sshd_config
sed -i 's/#PermitRootLogin without-password/PermitRootLogin no/' /etc/openssh/sshd_config
echo "AllowUsers userssh" >> /etc/openssh/sshd_config
echo "MaxAuthTries 2" >> /etc/openssh/sshd_config
echo "Banner /etc/openssh/banner" >> /etc/openssh/sshd_config

# Create banner
echo "Authorized access only" > /etc/openssh/banner

# Start SSH at boot and restart it
systemctl enable --now sshd
systemctl restart sshd

echo "Configuration complete:"
echo "- User: userssh (password: P@ssw0rd)"
echo "- SSH port: 2127"
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
check "Hostname = br-srv.tkhis.pro"              '[ "$(hostnamectl --static)" = "br-srv.tkhis.pro" ]'
check "User userssh created (UID 2027)"             '[ "$(id -u userssh)" = "2027" ]'
check "userssh is in group wheel"                   'id -nG userssh | grep -qw wheel'
check "userssh added to sudoers"                    'grep -q "userssh ALL=(ALL) NOPASSWD: ALL" /etc/sudoers'
check "SSH port changed to 2127"                    'grep -q "^Port 2127" /etc/openssh/sshd_config'
check "SSH root login disabled"                     'grep -q "^PermitRootLogin no" /etc/openssh/sshd_config'
check "AllowUsers userssh configured"               'grep -q "^AllowUsers userssh" /etc/openssh/sshd_config'
check "MaxAuthTries 2 configured"                   'grep -q "^MaxAuthTries 2" /etc/openssh/sshd_config'
check "SSH banner created"                          '[ -f /etc/openssh/banner ]'
check "SSH service active"                          'systemctl is-active --quiet sshd'
check "SSH enabled at boot"                         'systemctl is-enabled --quiet sshd'

echo "- Downloading inventory file"
apt-get update && apt-get install -y ansible sshpass
mkdir -p /etc/ansible
cd /etc/ansible
# The inventory lives in this repo as inventory2.yml
wget -O /etc/ansible/inventory.yml "$(dirname "$RAW_URL")/inventory2.yml"

cat > /etc/ansible/ansible.cfg <<EOF
[defaults]
interpreter_python = /usr/bin/python3
inventory = /etc/ansible/inventory.yml
host_key_checking = false
EOF

# ===========================================================
# Time zone (Alt JeOS can ship without the time zone database)
# ===========================================================
apt-get install -y tzdata
timedatectl set-timezone Asia/Krasnoyarsk || ln -sf /usr/share/zoneinfo/Asia/Krasnoyarsk /etc/localtime

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
search tkhis.pro
EOF
cp /etc/net/ifaces/enp7s1/resolv.conf /etc/resolv.conf

check "DNS on enp7s1: 192.168.100.2, search tkhis.pro" 'grep -qx "nameserver 192.168.100.2" /etc/net/ifaces/enp7s1/resolv.conf && grep -qx "search tkhis.pro" /etc/net/ifaces/enp7s1/resolv.conf'
check "ansible installed"                           'command -v ansible'
check "sshpass installed"                           'command -v sshpass'
check "inventory.yml downloaded"                    '[ -s /etc/ansible/inventory.yml ]'
check "ansible.cfg configured"                      'grep -qx "inventory = /etc/ansible/inventory.yml" /etc/ansible/ansible.cfg && grep -qx "host_key_checking = false" /etc/ansible/ansible.cfg'
check "tzdata installed"                            'rpm -q tzdata'
check "Local time is UTC+7 (Asia/Krasnoyarsk)"     '[ "$(date +%z)" = "+0700" ]'
check "chronyd active"                              'systemctl is-active --quiet chronyd'
check "chronyd enabled at boot"                     'systemctl is-enabled --quiet chronyd'
check "chrony.conf points to ISP (172.16.2.1)"     'grep -qx "server 172.16.2.1 iburst" /etc/chrony.conf'
check "Time synced from ISP (172.16.2.1)"          'chronyc -n sources | grep -q "^\^\* 172.16.2.1 "'
echo "=== Check complete, log saved to $LOG ===" | tee -a "$LOG"

# NEXT STEP banner: shown here and saved without colours to $NEXT
next_step() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN} NEXT STEP${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e " Next on this host: ${YELLOW}samba.sh${NC} - the domain controller for tkhis.pro."
    echo -e " Then, also on this host: ${YELLOW}docker.sh${NC} (testapp + MariaDB from the exam ISO)."
    echo -e " Use /etc/ansible/inventory.yml here to manage the lab with Ansible."
    echo -e "${CYAN}============================================================${NC}"
    echo
}
next_step
# Same text without colours, for later: cat <script>-next-step.txt
next_step | sed 's/\x1b\[[0-9;]*m//g' > "$NEXT"
echo -e " ${CYAN}(saved: cat $(basename "$NEXT"))${NC}"

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
rm -f "$LOG" "$NEXT" "$DIR/retry" "$DIR/delete" "$SELF"
DELEOF
chmod +x "$DIR/delete"

rm -f "$SELF"

# Ping SSH so ansible can work
apt-get install sshpass -y

# Each login only runs "hostname" and comes straight back: an interactive
# session here would leave you in another host's shell (and its ./retry)
# while the console still looks like BR-SRV
ssh_try() {
    if sshpass -p 'P@ssw0rd' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -p 2127 "$1" hostname 2>/dev/null; then
        echo "  ^ SSH OK: $1"
    else
        echo "SSH FAILED: $1" >&2
    fi
}
ssh_try admin@192.168.100.1
ssh_try admin@192.168.0.1
ssh_try userssh@192.168.100.2
ssh_try userssh@192.168.0.2

# --- Connect to the host with a dynamic IP (DHCP pool 192.168.200.2-192.168.200.6) ---
PORT=2127
USER=userssh
SUBNET=192.168.200
TIMEOUT=3
FOUND_IP=""

# bash's /dev/tcp instead of nc, which Alt does not ship by default;
# ping first so a dead address costs 1 s instead of a hanging connect
for i in $(seq 2 6); do
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
    echo "No host found on ${SUBNET}.2-6 port ${PORT} - hq-cli keeps its inventory address" >&2
fi

ansible -m ping all

[ -n "$FOUND_IP" ] && ssh_try "${USER}@${FOUND_IP}"

echo -e "${CYAN}You are on BR-SRV ($(hostname)).${NC}"

exec bash
