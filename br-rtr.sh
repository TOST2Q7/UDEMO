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

# Is there a firewall (BR-FW) between this router and BR-SRV?
#   yes: enp7s2 is the 192.168.1.0/30 link to BR-FW, which owns the branch
#        LAN gateway 192.168.0.1 (br-fw.sh)
#   no:  BR-SRV is plugged into enp7s2 directly, gateway 192.168.0.1 is here
# Empty = ask right away (Enter = yes); "BR_FW=no ./br-rtr.sh" skips the question
BR_FW="${BR_FW:-}"
# ===========================================================

# Ask first: the answer decides the LAN side of this router
choose_br_fw() {
    local ans
    case "$BR_FW" in yes|no) return ;; esac
    BR_FW="yes"
    { : </dev/tty; } 2>/dev/null || return
    echo
    echo " Is there a firewall BR-FW between BR-RTR and BR-SRV?"
    echo "   1) Yes: BR-RTR - 192.168.1.0/30 - BR-FW - 192.168.0.0/28 - BR-SRV (default)"
    echo "   2) No:  BR-SRV is plugged into BR-RTR directly, 192.168.0.0/28"
    while true; do
        read -r -p " Choice [1]: " ans </dev/tty
        case "$ans" in
            ""|1) BR_FW="yes"; return ;;
            2)    BR_FW="no";  return ;;
        esac
    done
}
choose_br_fw
if [ "$BR_FW" = "yes" ]; then
    LAN_ADDR="192.168.1.1/30"; LAN_NET="192.168.1.0/30"; OTHER_NET="192.168.0.0/28"
    LAN_PEER="192.168.1.2";    LAN_ROLE="link to BR-FW"
else
    LAN_ADDR="192.168.0.1/28"; LAN_NET="192.168.0.0/28"; OTHER_NET="192.168.1.0/30"
    LAN_PEER="192.168.0.2";    LAN_ROLE="BR LAN, BR-SRV"
fi
echo "BR-FW: $BR_FW - enp7s2 = $LAN_ADDR ($LAN_ROLE)"

hostnamectl set-hostname br-rtr.tkhis.pro

# Install gpasswd
apt-get install -y shadow-groups

# Enable routing (any spelling of the line, add it if it is missing)
sed -i 's/^#* *net\.ipv4\.ip_forward *=.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
grep -q "^net.ipv4.ip_forward = 1" /etc/net/sysctl.conf || echo "net.ipv4.ip_forward = 1" >> /etc/net/sysctl.conf
# and switch it on right now, not only on the next network restart
sysctl -w net.ipv4.ip_forward=1

# Create enp7s2: with BR-FW the /30 link to it, without BR-FW the branch
# LAN 192.168.0.0/28 itself with BR-SRV using this router (192.168.0.1).
# Own options instead of a copy of enp7s1: if enp7s1 is still on DHCP the
# copy would be too, and etcnet would ignore ipv4address
mkdir -p /etc/net/ifaces/enp7s2
cat > /etc/net/ifaces/enp7s2/options <<EOF
TYPE=eth
BOOTPROTO=static
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF
echo "$LAN_ADDR" > /etc/net/ifaces/enp7s2/ipv4address

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
echo "10.10.10.2/24" > /etc/net/ifaces/tun0/ipv4address

# Load GRE module and restart networking
modprobe ip_gre
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
# "no network $OTHER_NET" drops the other BR-FW scenario's network from a
# router set up by an earlier run; vtysh only complains if it is not there
vtysh << EOF
conf
router ospf
no network $OTHER_NET area 0
network $LAN_NET area 0
network 10.10.10.0/24 area 0
exit
int tun0
ip ospf authentication message-digest
ip ospf message-digest-key 1 md5 P@ssw0rd
ip ospf network broadcast
do wr
exit
EOF

echo "OSPF configuration complete!"

# Set up NAT
apt-get install iptables -y
iptables -t nat -A POSTROUTING -o enp7s1 -j MASQUERADE
# Forward port 2127 arriving from outside (WAN) to BR-SRV; matching the LAN
# address instead would hijack SSH to this router itself
iptables -t nat -A PREROUTING -i enp7s1 -p tcp --dport 2127 -j DNAT --to-destination 192.168.0.2:2127
# Forward 8080 to testapp on BR-SRV (docker.sh), ISP's nginx proxies to it
iptables -t nat -A PREROUTING -i enp7s1 -p tcp --dport 8080 -j DNAT --to-destination 192.168.0.2:8080
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables

# 1. Create user admin (OR ANOTHER USER, IF CHANGED UPDATE THE NAME ETC IN THIS FILE)
useradd -m admin

# 2. Set password P@ssw0rd (no confirmation)
echo "admin:P@ssw0rd" | chpasswd

# 3. Add to group wheel
gpasswd -a admin wheel

# 4. Configure passwordless sudo
echo "admin ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# 5. Configure SSH (port 2127, disable root login)
sed -i 's/#Port 22/Port 2127/' /etc/openssh/sshd_config
sed -i 's/#PermitRootLogin without-password/PermitRootLogin no/' /etc/openssh/sshd_config

# 6. Start SSH at boot and restart it
systemctl enable --now sshd
systemctl restart sshd

# sshpass: type the lab password for ssh/scp from this host without a prompt
apt-get install -y sshpass

echo "Done! User admin created, SSH configured on port 2127."

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
cat > /etc/net/ifaces/enp7s1/resolv.conf <<EOF
nameserver 192.168.100.2
search tkhis.pro
EOF
cp /etc/net/ifaces/enp7s1/resolv.conf /etc/resolv.conf

# tun0 is an OSPF broadcast network: the adjacency with HQ-RTR waits for
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
echo "=== Checking br-rtr configuration (BR-FW: $BR_FW) ===" | tee -a "$LOG"
check "Hostname = br-rtr.tkhis.pro"              '[ "$(hostnamectl --static)" = "br-rtr.tkhis.pro" ]'
check "tzdata installed"                            'rpm -q tzdata'
check "Local time is UTC+7 (Asia/Krasnoyarsk)"     '[ "$(date +%z)" = "+0700" ]'
check "IP forwarding enabled"                       'grep -q "^net.ipv4.ip_forward = 1" /etc/net/sysctl.conf'
check "IP forwarding active now"                    '[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]'
check "WAN 172.16.2.2/28 on enp7s1"                 'ip -4 addr show enp7s1 | grep -q "172.16.2.2/28"'
check "ISP reachable (172.16.2.1)"                  'ping -c 2 -W 1 172.16.2.1'
check "HQ-RTR WAN reachable (172.16.1.2)"           'ping -c 2 -W 1 172.16.1.2'
check "Interface enp7s2 is up"                       'ip addr show enp7s2'
check "Address $LAN_ADDR on enp7s2 ($LAN_ROLE)"    "ip -4 addr show enp7s2 | grep -q '$LAN_ADDR'"
check "Interface tun0 (GRE) is up"                  'ip link show tun0 | grep -q ",UP"'
check "tun0 is GRE 172.16.2.2 -> 172.16.1.2"        'ip -d link show tun0 | grep -q "gre remote 172.16.1.2 local 172.16.2.2"'
check "Address 10.10.10.2/24 on tun0"               'ip -4 addr show tun0 | grep -q "10.10.10.2/24"'
check "FRR is running"                              'systemctl is-active --quiet frr'
check "OSPF daemon enabled in FRR"                  'grep -q "ospfd=yes" /etc/frr/daemons'
check "OSPF network type on tun0 is broadcast"      'vtysh -c "show ip ospf interface tun0" | grep -q "Network Type BROADCAST"'
check "OSPF neighbour 10.10.10.1 is Full on tun0"   'vtysh -c "show ip ospf neighbor" | grep "10.10.10.1" | grep -q Full'
check "Tunnel to HQ-RTR responds (10.10.10.1)"      'ping -c 3 -W 1 10.10.10.1'
check "OSPF route to HQ responds (192.168.100.1)"   'ping -c 3 -W 1 192.168.100.1'
check "$LAN_ROLE reachable ($LAN_PEER)"            "ping -c 2 -W 1 $LAN_PEER"
check "NAT MASQUERADE configured"                   'iptables -t nat -C POSTROUTING -o enp7s1 -j MASQUERADE'
check "SSH DNAT (2127) configured"                  'iptables -t nat -C PREROUTING -i enp7s1 -p tcp --dport 2127 -j DNAT --to-destination 192.168.0.2:2127'
check "testapp DNAT (8080) configured"              'iptables -t nat -C PREROUTING -i enp7s1 -p tcp --dport 8080 -j DNAT --to-destination 192.168.0.2:8080'
check "iptables enabled at boot"                    'systemctl is-enabled --quiet iptables'
check "User admin exists"                           'id admin'
check "admin is in group wheel"                     'id -nG admin | grep -qw wheel'
check "admin added to sudoers"                      'grep -q "admin ALL=(ALL) NOPASSWD: ALL" /etc/sudoers'
check "SSH port changed to 2127"                    'grep -q "^Port 2127" /etc/openssh/sshd_config'
check "SSH root login disabled"                     'grep -q "^PermitRootLogin no" /etc/openssh/sshd_config'
check "SSH service active"                          'systemctl is-active --quiet sshd'
check "SSH enabled at boot"                         'systemctl is-enabled --quiet sshd'
check "sshpass installed"                           'command -v sshpass'
check "chronyd active"                              'systemctl is-active --quiet chronyd'
check "chronyd enabled at boot"                     'systemctl is-enabled --quiet chronyd'
check "chrony.conf points to ISP (172.16.2.1)"     'grep -qx "server 172.16.2.1 iburst" /etc/chrony.conf'
check "Time synced from ISP (172.16.2.1)"          'chronyc -n sources | grep -q "^\^\* 172.16.2.1 "'
check "DNS on enp7s1: 192.168.100.2, search tkhis.pro" 'grep -qx "nameserver 192.168.100.2" /etc/net/ifaces/enp7s1/resolv.conf && grep -qx "search tkhis.pro" /etc/net/ifaces/enp7s1/resolv.conf'
echo "=== Check complete, log saved to $LOG ===" | tee -a "$LOG"

# ===========================================================
# Create retry/delete helper files, then remove this script
# ===========================================================
cat > "$DIR/retry" <<RETRYEOF
#!/bin/bash
# $NAME left DNS pointing at HQ-SRV (192.168.100.2), which may not answer
# yet - go back to the public resolver for the download and the rerun
# (the script switches to HQ-SRV again at its end)
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
    if [ "$BR_FW" = "yes" ]; then
        echo -e " Run next : ${YELLOW}br-fw.sh${NC} on the branch firewall host"
        echo -e " Segment  : 192.168.1.0/30 (link BR-RTR - BR-FW)"
        echo
        echo -e " Before running it, set a static address on that host (enp7s1):"
        echo -e "   sed -i 's/^BOOTPROTO=.*/BOOTPROTO=static/' /etc/net/ifaces/enp7s1/options"
        echo -e "   echo 192.168.1.2/30 > /etc/net/ifaces/enp7s1/ipv4address"
        echo -e "   echo 'default via 192.168.1.1' > /etc/net/ifaces/enp7s1/ipv4route"
        OTHER="no"
    else
        echo -e " Run next : ${YELLOW}br-srv.sh${NC} on the branch server host"
        echo -e " Segment  : 192.168.0.0/28 (flat, no VLAN), gateway is this BR-RTR"
        echo
        echo -e " Before running it, set a static address on that host (enp7s1):"
        echo -e "   sed -i 's/^BOOTPROTO=.*/BOOTPROTO=static/' /etc/net/ifaces/enp7s1/options"
        echo -e "   echo 192.168.0.2/28 > /etc/net/ifaces/enp7s1/ipv4address"
        echo -e "   echo 'default via 192.168.0.1' > /etc/net/ifaces/enp7s1/ipv4route"
        OTHER="yes"
    fi
    echo -e "   echo 'nameserver 77.88.8.8' > /etc/net/ifaces/enp7s1/resolv.conf"
    echo -e "   systemctl restart network"
    echo -e " Wrong BR-FW answer? Rerun this router: ${YELLOW}BR_FW=$OTHER ./retry${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo
}
next_step
# Same text without colours, for later: cat <script>-next-step.txt
next_step | sed 's/\x1b\[[0-9;]*m//g' > "$NEXT"
echo -e " ${CYAN}(saved: cat $(basename "$NEXT"))${NC}"

exec bash
