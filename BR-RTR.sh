#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/main/$NAME"
# ===========================================================

hostnamectl set-hostname br-rtr.au-team.irpo

# Install gpasswd
apt-get install shadow-groups

# Enable routing
sed -i "s/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/" "/etc/net/sysctl.conf"

# Create enp7s2
mkdir -p /etc/net/ifaces/enp7s2
cp -r /etc/net/ifaces/enp7s1/options /etc/net/ifaces/enp7s2/options
echo "192.168.0.1/28" > /etc/net/ifaces/enp7s2/ipv4address

# Create tunnel directory and config files
mkdir -p /etc/net/ifaces/tun0

# options file
cat > /etc/net/ifaces/tun0/options <<EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.2.2
TUNREMOTE=172.16.1.2
TUNTTL=64
TUNOPTIONS='ttl 64'
HOST=enp7s1
EOF

# ipv4address file
echo "10.10.10.2/30" > /etc/net/ifaces/tun0/ipv4address

# Load GRE module and restart networking
modprobe gre
systemctl restart network

echo "Tunnel configured"

# Install FRR (if not installed)
apt-get install -y frr

# Enable OSPF in /etc/frr/daemons (ospfd=no -> ospfd=yes)
sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons

# Reload daemon and start FRR
systemctl daemon-reload
systemctl enable --now frr

# Configure OSPF via vtysh (automatic input) CHANGE TO YOUR OWN ADDRESSES
vtysh << 'EOF'
conf
router ospf
network 192.168.0.0/28 area 0
network 10.10.10.0/30 area 0
exit
int tun0
ip ospf authentication message-digest
ip ospf message-digest-key 1 md5 P@ssw0rd
do wr
exit
EOF

echo "OSPF configuration complete!"

# Set up NAT
apt-get install iptables -y
iptables -t nat -A POSTROUTING -o enp7s1 -j MASQUERADE
iptables -t nat -A PREROUTING -p tcp -d 192.168.0.1 --dport 2027 -j DNAT --to-destination 192.168.0.2:2027
iptables-save >> /etc/sysconfig/iptables
systemctl enable --now iptables

# 1. Create user net_admin (OR ANOTHER USER, IF CHANGED UPDATE THE NAME ETC IN THIS FILE)
useradd -m net_admin

# 2. Set password P@ssw0rd (no confirmation)
echo "net_admin:P@ssw0rd" | chpasswd

# 3. Add to group wheel
gpasswd -a net_admin wheel

# 4. Configure passwordless sudo
echo "net_admin ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# 5. Configure SSH (port 2027, disable root login)
sed -i 's/#Port 22/Port 2027/' /etc/openssh/sshd_config
sed -i 's/#PermitRootLogin without-password/PermitRootLogin no/' /etc/openssh/sshd_config

# 6. Restart SSH
systemctl restart sshd

echo "Done! User net_admin created, SSH configured on port 2027."

# ===========================================================
# Final check of everything this script configured
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
echo "=== Checking br-rtr configuration ===" | tee -a "$LOG"
check "Hostname = br-rtr.au-team.irpo"              '[ "$(hostnamectl --static)" = "br-rtr.au-team.irpo" ]'
check "IP forwarding enabled"                       'grep -q "net.ipv4.ip_forward = 1" /etc/net/sysctl.conf'
check "Interface enp7s2 is up"                       'ip addr show enp7s2'
check "Address 192.168.0.1/28 on enp7s2"            'ip -4 addr show enp7s2 | grep -q "192.168.0.1/28"'
check "Interface tun0 (GRE) is up"                   'ip addr show tun0'
check "Address 10.10.10.2/30 on tun0"               'ip -4 addr show tun0 | grep -q "10.10.10.2/30"'
check "FRR is running"                              'systemctl is-active --quiet frr'
check "OSPF daemon enabled in FRR"                  'grep -q "ospfd=yes" /etc/frr/daemons'
check "Tunnel to ISP responds (10.10.10.1)"         'ping -c 3 -W 1 10.10.10.1'
check "OSPF route to HQ responds (192.168.100.1)"   'ping -c 3 -W 1 192.168.100.1'
check "NAT MASQUERADE configured"                   'iptables -t nat -C POSTROUTING -o enp7s1 -j MASQUERADE'
check "SSH DNAT (2027) configured"                  'iptables -t nat -C PREROUTING -p tcp -d 192.168.0.1 --dport 2027 -j DNAT --to-destination 192.168.0.2:2027'
check "iptables enabled at boot"                    'systemctl is-enabled --quiet iptables'
check "User net_admin exists"                       'id net_admin'
check "net_admin is in group wheel"                 'id -nG net_admin | grep -qw wheel'
check "net_admin added to sudoers"                  'grep -q "net_admin ALL=(ALL) NOPASSWD: ALL" /etc/sudoers'
check "SSH port changed to 2027"                    'grep -q "^Port 2027" /etc/openssh/sshd_config'
check "SSH root login disabled"                     'grep -q "^PermitRootLogin no" /etc/openssh/sshd_config'
check "SSH service active"                          'systemctl is-active --quiet sshd'
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
echo -e " Run next : ${YELLOW}BR-SRV.sh${NC} on the branch server host"
echo -e " Segment  : 192.168.0.0/28 (flat, no VLAN)"
echo
echo -e " Before running it, set a static address on that host (enp7s1):"
echo -e "   echo 192.168.0.2/28 > /etc/net/ifaces/enp7s1/ipv4address"
echo -e "   echo 192.168.0.1 > /etc/net/ifaces/enp7s1/ipv4route"
echo -e "   echo 'nameserver 77.88.8.8' > /etc/net/ifaces/enp7s1/resolv.conf"
echo -e "   systemctl restart network"
echo -e "${CYAN}============================================================${NC}"
echo

exec bash
