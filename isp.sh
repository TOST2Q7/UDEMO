#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/checks/$NAME"
# ===========================================================

# Set hostname
hostnamectl set-hostname isp.au-team.irpo

# Set timezone (Alt JeOS can ship without the time zone database)
apt-get update
apt-get install -y tzdata
if [ -z "$(find /usr/share/zoneinfo -name Krasnoyarsk)" ]; then
    echo "Asia/Krasnoyarsk not found in /usr/share/zoneinfo - tzdata did not install" >&2
elif ! timedatectl set-timezone Asia/Krasnoyarsk; then
    # timedatectl does not know the zone: point /etc/localtime at it by hand
    rm -f /etc/localtime
    ln -s /usr/share/zoneinfo/Asia/Krasnoyarsk /etc/localtime
fi
timedatectl | grep "Time zone"
ls -l /etc/localtime
date

# NTP server: serve the local clock as stratum 5 to every other host
# (the LANs reach it NAT'ed as the routers' 172.16.x.2 WAN addresses)
apt-get install -y chrony
cat > /etc/chrony.conf <<EOF
local stratum 5
allow 172.16.0.0/16
allow 192.168.0.0/16
allow 10.10.10.0/30
EOF
systemctl enable --now chronyd
systemctl restart chronyd
# The local reference takes a moment to kick in after a restart
for i in $(seq 10); do
    chronyc tracking | grep -qE '^Stratum +: 5$' && break
    sleep 1
done

# Create interface directories
mkdir -p /etc/net/ifaces/{enp7s2,enp7s3}

# Configure interface enp7s2 (static IP)
cat <<EOF > /etc/net/ifaces/enp7s2/options
BOOTPROTO=static
TYPE=eth
CONFIG_WIRELESS=no
SYSTEMD_BOOTPROTO=dhcp4
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF

# Configure interface enp7s3 (static IP)
cat <<EOF > /etc/net/ifaces/enp7s3/options
BOOTPROTO=static
TYPE=eth
CONFIG_WIRELESS=no
SYSTEMD_BOOTPROTO=dhcp4
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF

# Set static addresses for the interfaces
echo '172.16.1.1/28' > /etc/net/ifaces/enp7s2/ipv4address
echo '172.16.2.1/28' > /etc/net/ifaces/enp7s3/ipv4address

# Enable routing
sed -i "s/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/" "/etc/net/sysctl.conf"

# Configure NAT
apt-get install iptables -y

iptables -t nat -A POSTROUTING -o enp7s1 -j MASQUERADE
iptables-save > /etc/sysconfig/iptables

# Enable iptables at boot
systemctl enable --now iptables

# Restart networking
systemctl restart network

# Allow root login over SSH
sed -i 's/#*PermitRootLogin.*/PermitRootLogin yes/' /etc/openssh/sshd_config

# Restart sshd
systemctl enable --now sshd
systemctl restart sshd.service

apt-get update

# ===========================================================
# Pre-fetch gost-isp.sh (used much later, once gost.sh on HQ-SRV
# has delivered certificates here) so it is already on disk when
# needed - do not run it yet, the certs do not exist until then
# ===========================================================
wget -O "$DIR/gost-isp.sh" "$(dirname "$RAW_URL")/gost-isp.sh" && chmod +x "$DIR/gost-isp.sh" \
    || echo "Could not pre-fetch gost-isp.sh, fetch it manually later" >&2

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
echo "=== Checking isp configuration ===" | tee -a "$LOG"
check "Hostname = isp.au-team.irpo"                 '[ "$(hostnamectl --static)" = "isp.au-team.irpo" ]'
check "tzdata installed"                            'rpm -q tzdata'
check "/etc/localtime -> Asia/Krasnoyarsk"          'readlink /etc/localtime | grep -q "Asia/Krasnoyarsk$"'
check "Local time is UTC+7"                         '[ "$(date +%z)" = "+0700" ]'
check "chronyd active"                              'systemctl is-active --quiet chronyd'
check "chronyd enabled at boot"                     'systemctl is-enabled --quiet chronyd'
check "chrony.conf: local stratum 5"                'grep -qx "local stratum 5" /etc/chrony.conf'
check "NTP server runs at stratum 5"                'chronyc tracking | grep -qE "^Stratum +: 5$"'
check "Interface enp7s2 is up"                       'ip addr show enp7s2'
check "Address 172.16.1.1/28 on enp7s2"             'ip -4 addr show enp7s2 | grep -q "172.16.1.1/28"'
check "Interface enp7s3 is up"                       'ip addr show enp7s3'
check "Address 172.16.2.1/28 on enp7s3"             'ip -4 addr show enp7s3 | grep -q "172.16.2.1/28"'
check "IP forwarding enabled"                       'grep -q "net.ipv4.ip_forward = 1" /etc/net/sysctl.conf'
check "NAT MASQUERADE configured"                   'iptables -t nat -C POSTROUTING -o enp7s1 -j MASQUERADE'
check "iptables enabled at boot"                    'systemctl is-enabled --quiet iptables'
check "SSH root login allowed"                      'grep -q "^PermitRootLogin yes" /etc/openssh/sshd_config'
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
rm -f "$LOG" "$DIR/gost-isp.sh" "$DIR/retry" "$DIR/delete" "$SELF"
DELEOF
chmod +x "$DIR/delete"

rm -f "$SELF"

echo
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} NEXT STEP${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e " Run next : ${YELLOW}hq-rtr.sh${NC} (HQ router) and ${YELLOW}br-rtr.sh${NC} (branch router)"
echo -e " Segment  : WAN uplinks toward this ISP"
echo -e " (gost-isp.sh was pre-fetched into this directory - run it much"
echo -e "  later, once gost.sh on HQ-SRV has delivered certificates here)"
echo
echo -e " Before running them, set static WAN addresses on each router (enp7s1):"
echo
echo -e "   HQ router (enp7s1):"
echo -e "     echo 172.16.1.2/28 > /etc/net/ifaces/enp7s1/ipv4address"
echo -e "     echo 'default via 172.16.1.1' > /etc/net/ifaces/enp7s1/ipv4route"
echo -e "     echo 'nameserver 77.88.8.8' > /etc/net/ifaces/enp7s1/resolv.conf"
echo
echo -e "   Branch router (enp7s1):"
echo -e "     echo 172.16.2.2/28 > /etc/net/ifaces/enp7s1/ipv4address"
echo -e "     echo 'default via 172.16.2.1' > /etc/net/ifaces/enp7s1/ipv4route"
echo -e "     echo 'nameserver 77.88.8.8' > /etc/net/ifaces/enp7s1/resolv.conf"
echo
echo -e "   On both: systemctl restart network"
echo -e "${CYAN}============================================================${NC}"
echo

exec bash
