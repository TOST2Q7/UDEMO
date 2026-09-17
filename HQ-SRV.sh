#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/main/$NAME"
# ===========================================================

hostnamectl set-hostname hq-srv.au-team.irpo

# Install wget
apt-get update && apt-get install wget
# Configure DNS
wget raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/main/dnsmasq.conf
apt-get install -y dnsmasq
systemctl enable --now dnsmasq
rm -rf /etc/dnsmasq.conf
cp -r dnsmasq.conf /etc/
systemctl restart dnsmasq
ping -c 4 HQ-SRV.au-team.irpo

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

# Restart SSH
systemctl restart sshd

echo "Configuration complete:"
echo "- User: sshuser (password: P@ssw0rd)"
echo "- SSH port: 2027"
echo "- Root login disabled"
echo "- Banner created"

echo "Configuring RAID"
# Create RAID 0
mdadm --create --verbose /dev/md0 -l 0 -n 3 /dev/sd[b-d]

# Save configuration
mdadm --detail -scan > /etc/mdadm.conf

# fdisk work (automatic input of 'n' and 'w')
echo -e "n\n\n\n\n\nw" | fdisk /dev/md0

# Format partition
mkfs.ext4 /dev/md0p1

# Create directory and mount
mkdir /raid

# Add to fstab
echo "/dev/md0p1 /raid ext4 defaults 0 0" >> /etc/fstab
mount -a

# Install NFS
apt-get install -y nfs-server
systemctl enable --now nfs

# Configure NFS
mkdir /raid/nfs
chown -R 99:99 /raid/nfs
chmod 777 /raid/nfs

# Add NFS export CHANGE TO YOUR OWN NETWORKS
echo "/raid/nfs 192.168.200.0/28(rw,sync,no_subtree_check)" >> /etc/exports

# Restart NFS and create a test file
systemctl restart nfs
touch /raid/nfs/test

echo "Done! RAID and NFS configured."

echo "- Configuring resolv.conf"
# /etc/resolv.conf file
cat > /etc/resolv.conf <<EOF
    nameserver 127.0.0.1
    search au-team.irpo

EOF
chattr +i /etc/resolv.conf

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
echo "=== Checking hq-srv configuration ===" | tee -a "$LOG"
check "Hostname = hq-srv.au-team.irpo"              '[ "$(hostnamectl --static)" = "hq-srv.au-team.irpo" ]'
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
check "RAID array /dev/md0 exists"                  'grep -q "^md0 :" /proc/mdstat'
check "/etc/mdadm.conf saved"                       '[ -s /etc/mdadm.conf ]'
check "/raid is mounted"                            'mountpoint -q /raid'
check "/raid added to fstab"                        'grep -q "/dev/md0p1 /raid" /etc/fstab'
check "NFS server active"                           'systemctl is-active --quiet nfs'
check "/raid/nfs directory exists"                  '[ -d /raid/nfs ]'
check "NFS export configured"                       'grep -q "^/raid/nfs 192.168.200.0/28" /etc/exports'
check "NFS test file created"                       '[ -f /raid/nfs/test ]'
check "/etc/resolv.conf contains nameserver 127.0.0.1" 'grep -q "nameserver 127.0.0.1" /etc/resolv.conf'
check "/etc/resolv.conf is immutable"               'lsattr /etc/resolv.conf | grep -q "i"'
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
rm -f "$LOG" "$DIR/dnsmasq.conf" "$DIR/retry" "$DIR/delete" "$SELF"
DELEOF
chmod +x "$DIR/delete"

rm -f "$SELF"

echo
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} NEXT STEP${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e " Run next : ${YELLOW}HQ-RTR-2.sh${NC} on the HQ router"
echo -e " Reason   : switches the DHCP-advertised DNS server from the"
echo -e "            public resolver (77.88.8.8) to this host"
echo -e "            (192.168.100.2), now that dnsmasq here is serving"
echo -e "            the au-team.irpo zone."
echo
echo -e " In parallel : ${YELLOW}samba.sh${NC} can now be deployed on the domain"
echo -e "               controller (VLAN 999, 192.168.99.0/29) - it"
echo -e "               forwards its own DNS queries to this host."
echo -e "   echo 192.168.99.2/29 > /etc/net/ifaces/enp7s1/ipv4address"
echo -e "   echo 192.168.99.1 > /etc/net/ifaces/enp7s1/ipv4route"
echo -e "   echo 'nameserver 77.88.8.8' > /etc/net/ifaces/enp7s1/resolv.conf"
echo -e "   systemctl restart network"
echo -e "${CYAN}============================================================${NC}"
echo
