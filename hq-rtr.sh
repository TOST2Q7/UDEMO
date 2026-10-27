#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/checks/$NAME"
# ===========================================================

hostnamectl set-hostname hq-rtr.au-team.irpo

# Install gpasswd
apt-get install shadow-groups -y

# Create enp7s2
mkdir -p /etc/net/ifaces/enp7s2
cp -r /etc/net/ifaces/enp7s1/options /etc/net/ifaces/enp7s2/options

# Create VLAN 100
mkdir -p /etc/net/ifaces/enp7s2.100/
cat > /etc/net/ifaces/enp7s2.100/options <<EOF
TYPE=vlan
HOST=enp7s2
VID=100
BOOTPROTO=static
EOF

# Create VLAN 200
mkdir -p /etc/net/ifaces/enp7s2.200/
cat > /etc/net/ifaces/enp7s2.200/options <<EOF
TYPE=vlan
HOST=enp7s2
VID=200
BOOTPROTO=static
EOF

# Create VLAN 999
mkdir -p /etc/net/ifaces/enp7s2.999/
cat > /etc/net/ifaces/enp7s2.999/options <<EOF
TYPE=vlan
HOST=enp7s2
VID=999
BOOTPROTO=static
EOF
echo "192.168.100.1/27" > /etc/net/ifaces/enp7s2.100/ipv4address
echo "192.168.200.1/28" > /etc/net/ifaces/enp7s2.200/ipv4address
echo "192.168.99.1/29" > /etc/net/ifaces/enp7s2.999/ipv4address

# Enable routing (any spelling of the line, add it if it is missing)
sed -i 's/^#* *net\.ipv4\.ip_forward *=.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
grep -q "^net.ipv4.ip_forward = 1" /etc/net/sysctl.conf || echo "net.ipv4.ip_forward = 1" >> /etc/net/sysctl.conf
# and switch it on right now, not only on the next network restart
sysctl -w net.ipv4.ip_forward=1

# Restart networking
systemctl restart network

# Install and configure dnsmasq
apt-get update && apt-get install -y dnsmasq
cat > /etc/dnsmasq.conf <<EOF
no-resolv
domain=au-team.irpo
dhcp-range=192.168.200.2,192.168.200.10,999h
dhcp-option=3,192.168.200.1
dhcp-option=6,77.88.8.8
dhcp-option=15,au-team.irpo
interface=enp7s2.200
EOF

# Enable and start dnsmasq
systemctl enable --now dnsmasq
systemctl restart dnsmasq

# Create tunnel directory and config files
mkdir -p /etc/net/ifaces/tun0

# options file
cat > /etc/net/ifaces/tun0/options <<EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.1.2
TUNREMOTE=172.16.2.2
TUNTTL=64
TUNOPTIONS='ttl 64'
HOST=enp7s1
EOF

# ipv4address file
echo "10.10.10.1/30" > /etc/net/ifaces/tun0/ipv4address

# Load GRE module and restart networking
modprobe gre
systemctl restart network

echo "Tunnel configured"

# Install FRR (if not installed)
apt-get install frr -y

# Enable OSPF in /etc/frr/daemons (ospfd=no -> ospfd=yes)
sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons

# Reload daemon and start FRR
systemctl daemon-reload
systemctl enable --now frr

# Configure OSPF via vtysh (automatic input) CHANGE TO YOUR OWN ADDRESSES
vtysh << 'EOF'
conf
router ospf
network 192.168.100.0/27 area 0
network 192.168.200.0/28 area 0
network 192.168.99.0/29 area 0
network 10.10.10.0/30 area 0
exit
int tun0
ip ospf authentication message-digest
ip ospf message-digest-key 1 md5 P@ssw0rd
ip ospf network broadcast
no ip ospf passive
do wr
exit
EOF

echo "OSPF configuration complete!"

# Set up NAT
apt-get install iptables -y
iptables -t nat -A POSTROUTING -o enp7s1 -j MASQUERADE
# Forward 8080 to the site on HQ-SRV (web.sh), ISP's nginx proxies to it
iptables -t nat -A PREROUTING -i enp7s1 -p tcp --dport 8080 -j DNAT --to-destination 192.168.100.2:80
# Forward SSH (2027) arriving from outside (WAN) to HQ-SRV; matching the
# LAN address instead would hijack SSH to this router itself
iptables -t nat -A PREROUTING -i enp7s1 -p tcp --dport 2027 -j DNAT --to-destination 192.168.100.2:2027
iptables-save > /etc/sysconfig/iptables
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

# 6. Start SSH at boot and restart it
systemctl enable --now sshd
systemctl restart sshd

# sshpass: type the lab password for ssh/scp from this host without a prompt
apt-get install -y sshpass

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
server 172.16.1.1 iburst
EOF
systemctl enable --now chronyd
systemctl restart chronyd
# Give the first sync up to ~30 s so the check below sees it
chronyc waitsync 15 0 0 2 >/dev/null

# ===========================================================
# DNS stays on the public resolver: HQ-SRV is not configured yet.
# hq-rtr-2.sh switches this router to HQ-SRV (192.168.100.2) after
# hq-srv.sh has brought up dnsmasq there.
# ===========================================================
cat > /etc/net/ifaces/enp7s1/resolv.conf <<EOF
nameserver 77.88.8.8
EOF
cp /etc/net/ifaces/enp7s1/resolv.conf /etc/resolv.conf

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
echo "=== Checking hq-rtr configuration ===" | tee -a "$LOG"
check "Hostname = hq-rtr.au-team.irpo"              '[ "$(hostnamectl --static)" = "hq-rtr.au-team.irpo" ]'
check "tzdata installed"                            'rpm -q tzdata'
check "Local time is UTC+7 (Asia/Krasnoyarsk)"     '[ "$(date +%z)" = "+0700" ]'
check "IP forwarding enabled"                       'grep -q "^net.ipv4.ip_forward = 1" /etc/net/sysctl.conf'
check "IP forwarding active now"                    '[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]'
check "Internet from this router (77.88.8.8)"       'ping -c 2 -W 2 77.88.8.8'
check "Internet via NAT from VLAN100 (src .100.1)"  'ping -c 2 -W 2 -I 192.168.100.1 77.88.8.8'
check "VLAN100 (enp7s2.100) is up"                  'ip addr show enp7s2.100'
check "Address 192.168.100.1/27 on enp7s2.100"      'ip -4 addr show enp7s2.100 | grep -q "192.168.100.1/27"'
check "VLAN200 (enp7s2.200) is up"                  'ip addr show enp7s2.200'
check "Address 192.168.200.1/28 on enp7s2.200"      'ip -4 addr show enp7s2.200 | grep -q "192.168.200.1/28"'
check "VLAN999 (enp7s2.999) is up"                  'ip addr show enp7s2.999'
check "Address 192.168.99.1/29 on enp7s2.999"       'ip -4 addr show enp7s2.999 | grep -q "192.168.99.1/29"'
check "dnsmasq is running"                          'systemctl is-active --quiet dnsmasq'
check "dnsmasq enabled at boot"                     'systemctl is-enabled --quiet dnsmasq'
check "dnsmasq listens on VLAN200"                  'grep -q "^interface=enp7s2.200$" /etc/dnsmasq.conf'
check "Interface tun0 (GRE) is up"                  'ip addr show tun0'
check "Address 10.10.10.1/30 on tun0"               'ip -4 addr show tun0 | grep -q "10.10.10.1/30"'
check "FRR is running"                              'systemctl is-active --quiet frr'
check "OSPF daemon enabled in FRR"                  'grep -q "ospfd=yes" /etc/frr/daemons'
check "OSPF network type on tun0 is broadcast"      'vtysh -c "show ip ospf interface tun0" | grep -q "Network Type BROADCAST"'
check "Tunnel to branch responds (10.10.10.2)"      'ping -c 3 -W 1 10.10.10.2'
check "HQ-SRV reachable (192.168.100.2)"            'ping -c 3 -W 1 192.168.100.2'
check "NAT MASQUERADE configured"                   'iptables -t nat -C POSTROUTING -o enp7s1 -j MASQUERADE'
check "Site DNAT (8080 -> HQ-SRV:80) configured"    'iptables -t nat -C PREROUTING -i enp7s1 -p tcp --dport 8080 -j DNAT --to-destination 192.168.100.2:80'
check "SSH DNAT (2027 -> HQ-SRV:2027) configured"   'iptables -t nat -C PREROUTING -i enp7s1 -p tcp --dport 2027 -j DNAT --to-destination 192.168.100.2:2027'
check "iptables enabled at boot"                    'systemctl is-enabled --quiet iptables'
check "User net_admin exists"                       'id net_admin'
check "net_admin is in group wheel"                 'id -nG net_admin | grep -qw wheel'
check "net_admin added to sudoers"                  'grep -q "net_admin ALL=(ALL) NOPASSWD: ALL" /etc/sudoers'
check "SSH port changed to 2027"                    'grep -q "^Port 2027" /etc/openssh/sshd_config'
check "SSH root login disabled"                     'grep -q "^PermitRootLogin no" /etc/openssh/sshd_config'
check "SSH service active"                          'systemctl is-active --quiet sshd'
check "SSH enabled at boot"                         'systemctl is-enabled --quiet sshd'
check "sshpass installed"                           'command -v sshpass'
check "chronyd active"                              'systemctl is-active --quiet chronyd'
check "chronyd enabled at boot"                     'systemctl is-enabled --quiet chronyd'
check "chrony.conf points to ISP (172.16.1.1)"     'grep -qx "server 172.16.1.1 iburst" /etc/chrony.conf'
check "Time synced from ISP (172.16.1.1)"          'chronyc -n sources | grep -q "^\^\* 172.16.1.1 "'
check "DNS on enp7s1: 77.88.8.8 (HQ-SRV comes later)" 'grep -qx "nameserver 77.88.8.8" /etc/net/ifaces/enp7s1/resolv.conf'
check "Name resolution works"                       'getent hosts raw.githubusercontent.com'
echo "=== Check complete, log saved to $LOG ===" | tee -a "$LOG"

# ===========================================================
# Create retry/delete helper files, then remove this script
# ===========================================================
cat > "$DIR/retry" <<RETRYEOF
#!/bin/bash
# hq-rtr-2.sh may have pointed DNS at HQ-SRV (192.168.100.2) - use the
# public resolver for the download; rerun hq-rtr-2.sh afterwards
echo 'nameserver 77.88.8.8' > /etc/net/ifaces/enp7s1/resolv.conf
cp /etc/net/ifaces/enp7s1/resolv.conf /etc/resolv.conf
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

echo "Done! User net_admin created, SSH configured on port 2027."

echo
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} NEXT STEP${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e " Run next : ${YELLOW}hq-srv.sh${NC} on the HQ server host"
echo -e " Segment  : VLAN 100, 192.168.100.0/27"
echo
echo -e " Proxmox tags VLAN 100 for that host: its NIC has VLAN Tag=100,"
echo -e " this router's NIC has no tag, the bridge is VLAN aware. Inside"
echo -e " HQ-SRV the address goes straight on enp7s1, no enp7s1.100:"
echo -e "   rm -rf /etc/net/ifaces/enp7s1.100"
echo -e "   sed -i 's/^BOOTPROTO=.*/BOOTPROTO=static/' /etc/net/ifaces/enp7s1/options"
echo -e "   echo 192.168.100.2/27 > /etc/net/ifaces/enp7s1/ipv4address"
echo -e "   echo 'default via 192.168.100.1' > /etc/net/ifaces/enp7s1/ipv4route"
echo -e "   echo 'nameserver 77.88.8.8' > /etc/net/ifaces/enp7s1/resolv.conf"
echo -e "   systemctl restart network"
echo -e "   ping -c2 192.168.100.1 && ping -c2 77.88.8.8"
echo -e " hq-srv.sh checks this link first and stops with a hint if it is down."
echo -e "${CYAN}============================================================${NC}"
echo

exec bash
