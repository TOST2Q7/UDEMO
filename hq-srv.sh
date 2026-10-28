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

# VLAN 100 reaches this host one of two ways (hq-rtr.sh asks which):
# Proxmox tags it and the address sits on enp7s1, or the VM tags it on enp7s1.100
IFACE="enp7s1"
[ -d /etc/net/ifaces/enp7s1.100 ] && IFACE="enp7s1.100"
# ===========================================================

# ===========================================================
# Network pre-flight: everything below downloads packages through
# HQ-RTR, so test the link step by step and stop with a hint
# ===========================================================
net_fail() {
    echo -e "\033[0;31m[NET FAIL] $1\033[0m"; shift
    for line in "$@"; do echo "  $line"; done
    echo "  Fix it and run this script again: $SELF"
    exit 1
}
# What to look at when HQ-RTR does not answer depends on the scenario
if [ "$IFACE" = "enp7s1.100" ]; then
    VLAN_HINT=("- Scenario: the VM tags VLAN 100 (enp7s1.100 found)"
               "- Proxmox: this NIC must have NO VLAN tag - Tag=100 plus enp7s1.100 = double"
               "  tag, no link. If Proxmox does tag it, switch scenario: on HQ-RTR"
               "  ./hq-srv-steps proxmox (no enp7s1.100, address on enp7s1)")
else
    VLAN_HINT=("- Scenario: Proxmox tags VLAN 100 (no enp7s1.100, address on enp7s1)"
               "- Proxmox: this NIC needs VLAN Tag=100, HQ-RTR's NIC no tag, both on the"
               "  same VLAN-aware bridge. If Proxmox does not tag it, switch scenario:"
               "  on HQ-RTR ./hq-srv-steps manual (enp7s1.100 inside this VM)")
fi
echo "=== Checking the link to HQ-RTR (VLAN 100 on $IFACE) ==="
ip -br addr
ip route
if ! ip -4 addr | grep -q "inet 192.168.100.2/28"; then
    net_fail "192.168.100.2/28 is not configured on this host" \
        "Put it on $IFACE as printed at the end of hq-rtr.sh (./hq-srv-steps there), then: systemctl restart network"
elif ! ping -c 2 -W 2 192.168.100.1 &>/dev/null; then
    net_fail "Gateway 192.168.100.1 (HQ-RTR) does not answer" \
        "${VLAN_HINT[@]}" \
        "- HQ-RTR: ip -br addr | grep enp7s2.100   -> must show 192.168.100.1/28"
elif ! ip route get 77.88.8.8 | grep -q "via 192.168.100.1 "; then
    net_fail "Internet traffic does not go via 192.168.100.1" \
        "Route in use: $(ip route get 77.88.8.8 2>&1 | head -1)" \
        "echo 'default via 192.168.100.1' > /etc/net/ifaces/$IFACE/ipv4route" \
        "systemctl restart network"
elif ! ping -c 2 -W 2 77.88.8.8 &>/dev/null; then
    net_fail "Gateway answers, but the internet (77.88.8.8) does not" \
        "On HQ-RTR:" \
        "  cat /proc/sys/net/ipv4/ip_forward                 -> must be 1 (sysctl -w net.ipv4.ip_forward=1)" \
        "  iptables -t nat -S POSTROUTING                    -> -o enp7s1 -j MASQUERADE" \
        "  ping -c2 -I 192.168.100.1 77.88.8.8               -> must answer"
elif ! getent hosts raw.githubusercontent.com &>/dev/null; then
    net_fail "Internet works, but names do not resolve" \
        "/etc/resolv.conf: $(grep -v '^#' /etc/resolv.conf | tr '\n' ' ')" \
        "chattr -i /etc/resolv.conf; echo 'nameserver 77.88.8.8' > /etc/resolv.conf"
fi
echo -e "\033[0;32m[OK] Gateway, internet and DNS work\033[0m"

hostnamectl set-hostname hq-srv.tkhis.pro

# Install wget
apt-get update && apt-get install -y wget
# Configure DNS
wget -O "$DIR/dnsmasq.conf" "$(dirname "$RAW_URL")/dnsmasq.conf"
apt-get install -y dnsmasq
systemctl enable --now dnsmasq
rm -rf /etc/dnsmasq.conf
cp "$DIR/dnsmasq.conf" /etc/
systemctl restart dnsmasq

echo "Configuring SSH"

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

# Start SSH at boot and restart it
systemctl enable --now sshd
systemctl restart sshd

# sshpass: type the lab password for ssh/scp from this host without a prompt
apt-get install -y sshpass

echo "Configuration complete:"
echo "- User: sshuser (password: P@ssw0rd)"
echo "- SSH port: 2027"
echo "- Root login disabled"
echo "- Banner created"

echo "Configuring RAID"
# Create RAID 5
mdadm --create --verbose /dev/md0 -l 5 -n 3 /dev/sd[b-d]

# Save configuration
mdadm --detail --scan > /etc/mdadm.conf

# fdisk work (automatic input of 'n' and 'w')
echo -e "n\n\n\n\n\nw" | fdisk /dev/md0

# Format partition
mkfs.ext4 /dev/md0p1

# Create directory and mount
mkdir /raid5

# Add to fstab
echo "/dev/md0p1 /raid5 ext4 defaults 0 0" >> /etc/fstab
mount -a

# Install NFS
apt-get install -y nfs-server
systemctl enable --now nfs

# Configure NFS
mkdir /raid5/nfs
chown -R 99:99 /raid5/nfs
chmod 777 /raid5/nfs

# Add NFS export CHANGE TO YOUR OWN NETWORKS
echo "/raid5/nfs 192.168.200.0/29(rw,sync,no_subtree_check)" >> /etc/exports

# Restart NFS and create a test file
systemctl restart nfs
touch /raid5/nfs/test

echo "Done! RAID and NFS configured."

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
# Point DNS at this host's own dnsmasq - done last, everything above
# still needs the public resolver
# ===========================================================
echo "- Configuring resolv.conf"
# Earlier versions of this script made it immutable
chattr -i /etc/resolv.conf 2>/dev/null
cat > /etc/net/ifaces/enp7s1/resolv.conf <<EOF
nameserver 127.0.0.1
search tkhis.pro
EOF
# Scenario "the VM tags VLAN 100": enp7s1.100 still holds the temporary
# 77.88.8.8 from setup and is the file etcnet applies
[ -d /etc/net/ifaces/enp7s1.100 ] && cp /etc/net/ifaces/enp7s1/resolv.conf /etc/net/ifaces/enp7s1.100/resolv.conf
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
echo "=== Checking hq-srv configuration (VLAN 100 on $IFACE) ===" | tee -a "$LOG"
check "Hostname = hq-srv.tkhis.pro"              '[ "$(hostnamectl --static)" = "hq-srv.tkhis.pro" ]'
check "tzdata installed"                            'rpm -q tzdata'
check "Local time is UTC+7 (Asia/Krasnoyarsk)"     '[ "$(date +%z)" = "+0700" ]'
check "Address 192.168.100.2/28 on $IFACE"          "ip -4 addr show $IFACE | grep -q 'inet 192.168.100.2/28'"
check "Default route via HQ-RTR (192.168.100.1)"    'ip route get 77.88.8.8 | grep -q "via 192.168.100.1 "'
check "Internet reachable (77.88.8.8)"              'ping -c 2 -W 2 77.88.8.8'
check "Internet names resolve via dnsmasq"          'getent hosts raw.githubusercontent.com'
check "dnsmasq is running"                          'systemctl is-active --quiet dnsmasq'
check "dnsmasq enabled at boot"                     'systemctl is-enabled --quiet dnsmasq'
check "/etc/dnsmasq.conf copied"                    '[ -s /etc/dnsmasq.conf ]'
check "User sshuser created (UID 2027)"             '[ "$(id -u sshuser)" = "2027" ]'
check "sshuser is in group wheel"                   'id -nG sshuser | grep -qw wheel'
check "sshuser added to sudoers"                    'grep -q "sshuser ALL=(ALL) NOPASSWD: ALL" /etc/sudoers'
check "SSH port changed to 2027"                    'grep -q "^Port 2027" /etc/openssh/sshd_config'
check "SSH root login disabled"                     'grep -q "^PermitRootLogin no" /etc/openssh/sshd_config'
check "AllowUsers sshuser configured"               'grep -q "^AllowUsers sshuser" /etc/openssh/sshd_config'
check "MaxAuthTries 2 configured"                   'grep -q "^MaxAuthTries 2" /etc/openssh/sshd_config'
check "SSH banner created"                          '[ -f /etc/openssh/banner ]'
check "SSH service active"                          'systemctl is-active --quiet sshd'
check "SSH enabled at boot"                         'systemctl is-enabled --quiet sshd'
check "sshpass installed"                           'command -v sshpass'
check "RAID array /dev/md0 exists"                  'grep -q "^md0 :" /proc/mdstat'
check "RAID level is 5"                             'grep -q "^md0 : active raid5" /proc/mdstat'
check "/etc/mdadm.conf saved"                       '[ -s /etc/mdadm.conf ]'
check "/raid5 is mounted"                           'mountpoint -q /raid5'
check "/raid5 added to fstab"                       'grep -q "/dev/md0p1 /raid5" /etc/fstab'
check "NFS server active"                           'systemctl is-active --quiet nfs'
check "/raid5/nfs directory exists"                 '[ -d /raid5/nfs ]'
check "NFS export configured"                       'grep -q "^/raid5/nfs 192.168.200.0/29" /etc/exports'
check "NFS test file created"                       '[ -f /raid5/nfs/test ]'
check "chronyd active"                              'systemctl is-active --quiet chronyd'
check "chronyd enabled at boot"                     'systemctl is-enabled --quiet chronyd'
check "chrony.conf points to ISP (172.16.1.1)"     'grep -qx "server 172.16.1.1 iburst" /etc/chrony.conf'
check "Time synced from ISP (172.16.1.1)"          'chronyc -n sources | grep -q "^\^\* 172.16.1.1 "'
check "DNS on $IFACE: 127.0.0.1, search tkhis.pro" "grep -qx 'nameserver 127.0.0.1' /etc/net/ifaces/$IFACE/resolv.conf && grep -qx 'search tkhis.pro' /etc/net/ifaces/$IFACE/resolv.conf"
check "/etc/resolv.conf uses 127.0.0.1"             'grep -qx "nameserver 127.0.0.1" /etc/resolv.conf'
check "Local DNS answers hq-srv.tkhis.pro"       'getent hosts hq-srv.tkhis.pro | grep -q "^192.168.100.2 "'
check "Local DNS answers moodle/wiki (CNAME)"       'getent hosts moodle.tkhis.pro && getent hosts wiki.tkhis.pro'
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
rm -f "$LOG" "$NEXT" "$DIR/dnsmasq.conf" "$DIR/retry" "$DIR/delete" "$SELF"
DELEOF
chmod +x "$DIR/delete"

rm -f "$SELF"

# NEXT STEP banner: shown here and saved without colours to $NEXT
next_step() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN} NEXT STEP${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e " Run next : ${YELLOW}hq-rtr-2.sh${NC} on the HQ router"
    echo -e " Reason   : switches the DHCP-advertised DNS server from the"
    echo -e "            public resolver (77.88.8.8) to this host"
    echo -e "            (192.168.100.2), now that dnsmasq here is serving"
    echo -e "            the tkhis.pro zone."
    echo
    echo -e " Later     : ${YELLOW}samba.sh${NC} goes on BR-SRV (the domain controller),"
    echo -e "             after br-srv.sh. This host already forwards tkhis.pro"
    echo -e "             to it (server=/tkhis.pro/192.168.0.2 in dnsmasq.conf),"
    echo -e "             and the DC forwards everything else back here."
    echo
    echo -e " Also      : ${YELLOW}web.sh${NC} on this host (the site + MariaDB from the"
    echo -e "             exam ISO - attach it as /dev/sr0 first):"
    echo -e "   wget -O web.sh $(dirname "$RAW_URL")/web.sh && bash web.sh"
    echo -e "${CYAN}============================================================${NC}"
    echo
}
next_step
# Same text without colours, for later: cat <script>-next-step.txt
next_step | sed 's/\x1b\[[0-9;]*m//g' > "$NEXT"
echo -e " ${CYAN}(saved: cat $(basename "$NEXT"))${NC}"

exec bash
