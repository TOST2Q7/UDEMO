#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
# NEXT STEP banner is also saved here: cat it to see the steps again
NEXT="$DIR/${NAME%.sh}-next-step.txt"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/checks/$NAME"

# BR-FW sits between BR-RTR and the branch LAN and filters what crosses it
WAN="enp7s1"   # toward BR-RTR: the internet and the tunnel to HQ (192.168.1.2/30, set by hand)
LAN="enp7s2"   # the branch LAN with BR-SRV (192.168.0.1/28)
# Internal networks that may reach the branch LAN freely: HQ through the
# tunnel, the tunnel itself and the link to BR-RTR. CHANGE TO YOUR OWN ADDRESSES
INT_NETS="192.168.100.0/27,192.168.200.0/28,192.168.99.0/29,10.10.10.0/30,192.168.1.0/30"
# BR-SRV and the ports BR-RTR forwards to it from the internet (SSH, testapp)
BR_SRV="192.168.0.2"
FWD_PORTS="2027,8080"
# ===========================================================

hostnamectl set-hostname br-fw.au-team.irpo

# Enable routing
sed -i "s/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/" "/etc/net/sysctl.conf"

# Create enp7s2: gateway of the branch LAN (BR-SRV keeps 192.168.0.1 as its gateway)
mkdir -p /etc/net/ifaces/$LAN
cp -r /etc/net/ifaces/$WAN/options /etc/net/ifaces/$LAN/options
echo "192.168.0.1/28" > /etc/net/ifaces/$LAN/ipv4address

systemctl restart network

# Install FRR (if not installed)
apt-get install -y frr

# Enable OSPF in /etc/frr/daemons (ospfd=no -> ospfd=yes)
sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons

# Reload daemon and start FRR
systemctl daemon-reload
systemctl enable --now frr

# Configure OSPF via vtysh (automatic input) CHANGE TO YOUR OWN ADDRESSES
# The LAN is only announced: passive means no hellos there, so nothing in
# the LAN can become a neighbour and inject routes
vtysh << 'EOF'
conf
router ospf
network 192.168.1.0/30 area 0
network 192.168.0.0/28 area 0
exit
int enp7s2
ip ospf passive
do wr
exit
EOF

echo "OSPF configuration complete!"

# ===========================================================
# Firewall. From the internet into the branch LAN only http, https,
# dns, ntp, icmp echo and the ports BR-RTR forwards to BR-SRV; the
# internal networks and the LAN itself pass. NAT stays on BR-RTR,
# which owns the public address
# ===========================================================
apt-get install -y iptables
# Start clean (a rerun finds the DROP policies already in place)
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -F INPUT
iptables -F FORWARD

# BR-FW itself: OSPF from BR-RTR, ping, anything from the LAN and the
# internal networks (SSH on 2027 for net_admin)
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i $WAN -p 89 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A INPUT -i $LAN -j ACCEPT
iptables -A INPUT -i $WAN -s $INT_NETS -j ACCEPT

# Traffic crossing BR-FW
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i $LAN -o $WAN -j ACCEPT
iptables -A FORWARD -i $WAN -o $LAN -s $INT_NETS -j ACCEPT
iptables -A FORWARD -i $WAN -o $LAN -p icmp --icmp-type echo-request -j ACCEPT
iptables -A FORWARD -i $WAN -o $LAN -p tcp -m multiport --dports 80,443,53 -j ACCEPT
iptables -A FORWARD -i $WAN -o $LAN -p udp -m multiport --dports 53,123 -j ACCEPT
iptables -A FORWARD -i $WAN -o $LAN -d $BR_SRV -p tcp -m multiport --dports $FWD_PORTS -j ACCEPT

# Drop the rest - policies go last so the rules above are already in place
iptables -P INPUT DROP
iptables -P FORWARD DROP

iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables

echo "Firewall configured!"

# Install gpasswd
apt-get install -y shadow-groups

# 1. Create user net_admin to manage BR-FW over SSH (OR ANOTHER USER, IF CHANGED UPDATE THE NAME ETC IN THIS FILE)
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

echo "Done! User net_admin created, SSH configured on port 2027."

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
# Point DNS at HQ-SRV - done last, everything above still needs
# the public resolver
# ===========================================================
cat > /etc/net/ifaces/$WAN/resolv.conf <<EOF
nameserver 192.168.100.2
search au-team.irpo
EOF
cp /etc/net/ifaces/$WAN/resolv.conf /etc/resolv.conf

# The link to BR-RTR is an OSPF broadcast network: the adjacency waits for
# the DR election (~40 s). Give it up to ~60 s so the route check sees it
for i in $(seq 30); do
    ping -c 1 -W 1 192.168.100.1 &>/dev/null && break
    sleep 1
done

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
echo "=== Checking br-fw configuration ===" | tee -a "$LOG"
check "Hostname = br-fw.au-team.irpo"               '[ "$(hostnamectl --static)" = "br-fw.au-team.irpo" ]'
check "tzdata installed"                            'rpm -q tzdata'
check "Local time is UTC+7 (Asia/Krasnoyarsk)"     '[ "$(date +%z)" = "+0700" ]'
check "IP forwarding enabled"                       'grep -q "net.ipv4.ip_forward = 1" /etc/net/sysctl.conf'
check "Address 192.168.1.2/30 on $WAN (to BR-RTR)" "ip -4 addr show $WAN | grep -q 192.168.1.2/30"
check "Address 192.168.0.1/28 on $LAN (LAN)"       "ip -4 addr show $LAN | grep -q 192.168.0.1/28"
check "FRR is running"                              'systemctl is-active --quiet frr'
check "OSPF daemon enabled in FRR"                  'grep -q "ospfd=yes" /etc/frr/daemons'
check "OSPF passive on $LAN"                        "vtysh -c 'show ip ospf interface $LAN' | grep -qi passive"
check "BR-RTR responds (192.168.1.1)"               'ping -c 3 -W 1 192.168.1.1'
check "OSPF route to HQ responds (192.168.100.1)"   'ping -c 3 -W 1 192.168.100.1'
check "Firewall: INPUT policy DROP"                 'iptables -S INPUT | grep -qx -- "-P INPUT DROP"'
check "Firewall: FORWARD policy DROP"               'iptables -S FORWARD | grep -qx -- "-P FORWARD DROP"'
check "Firewall: LAN may go out"                    "iptables -C FORWARD -i $LAN -o $WAN -j ACCEPT"
check "Firewall: SSH/testapp to BR-SRV allowed"     "iptables -C FORWARD -i $WAN -o $LAN -d $BR_SRV/32 -p tcp -m multiport --dports $FWD_PORTS -j ACCEPT"
check "Firewall: OSPF from BR-RTR allowed"          "iptables -C INPUT -i $WAN -p 89 -j ACCEPT"
check "Firewall rules saved for boot"               'grep -q "^:FORWARD DROP" /etc/sysconfig/iptables'
check "iptables enabled at boot"                    'systemctl is-enabled --quiet iptables'
check "User net_admin exists"                       'id net_admin'
check "net_admin is in group wheel"                 'id -nG net_admin | grep -qw wheel'
check "net_admin added to sudoers"                  'grep -q "net_admin ALL=(ALL) NOPASSWD: ALL" /etc/sudoers'
check "SSH port changed to 2027"                    'grep -q "^Port 2027" /etc/openssh/sshd_config'
check "SSH root login disabled"                     'grep -q "^PermitRootLogin no" /etc/openssh/sshd_config'
check "SSH service active"                          'systemctl is-active --quiet sshd'
check "SSH enabled at boot"                         'systemctl is-enabled --quiet sshd'
check "chronyd active"                              'systemctl is-active --quiet chronyd'
check "chronyd enabled at boot"                     'systemctl is-enabled --quiet chronyd'
check "chrony.conf points to ISP (172.16.2.1)"     'grep -qx "server 172.16.2.1 iburst" /etc/chrony.conf'
check "Time synced from ISP (172.16.2.1)"          'chronyc -n sources | grep -q "^\^\* 172.16.2.1 "'
check "DNS on $WAN: 192.168.100.2, search au-team.irpo" "grep -qx 'nameserver 192.168.100.2' /etc/net/ifaces/$WAN/resolv.conf && grep -qx 'search au-team.irpo' /etc/net/ifaces/$WAN/resolv.conf"
echo "=== Check complete, log saved to $LOG ===" | tee -a "$LOG"

# ===========================================================
# Create retry/delete helper files, then remove this script
# ===========================================================
cat > "$DIR/retry" <<RETRYEOF
#!/bin/bash
# $NAME left DNS pointing at HQ-SRV (192.168.100.2), which may not answer
# yet - go back to the public resolver for the download and the rerun
# (the script switches to HQ-SRV again at its end)
echo 'nameserver 77.88.8.8' > /etc/net/ifaces/$WAN/resolv.conf
cp /etc/net/ifaces/$WAN/resolv.conf /etc/resolv.conf
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

# NEXT STEP banner: shown here and saved without colours to $NEXT
next_step() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN} NEXT STEP${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e " Run next : ${YELLOW}br-srv.sh${NC} on the branch server host"
    echo -e " Segment  : 192.168.0.0/28 (flat, no VLAN), gateway is this BR-FW"
    echo
    echo -e " Before running it, set a static address on that host (enp7s1):"
    echo -e "   echo 192.168.0.2/28 > /etc/net/ifaces/enp7s1/ipv4address"
    echo -e "   echo 'default via 192.168.0.1' > /etc/net/ifaces/enp7s1/ipv4route"
    echo -e "   echo 'nameserver 77.88.8.8' > /etc/net/ifaces/enp7s1/resolv.conf"
    echo -e "   systemctl restart network"
    echo -e "${CYAN}============================================================${NC}"
    echo
}
next_step
# Same text without colours, for later: cat <script>-next-step.txt
next_step | sed 's/\x1b\[[0-9;]*m//g' > "$NEXT"
echo -e " ${CYAN}(saved: cat $(basename "$NEXT"))${NC}"

exec bash
