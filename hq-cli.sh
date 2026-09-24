#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/checks/$NAME"
# ===========================================================

apt-get update && apt-get install -y yandex-browser-stable

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

hostnamectl set-hostname hq-cli.au-team.irpo

# Mount NFS share
mkdir /mnt/nfs

# fstab entry
cat >> /etc/fstab <<EOF
192.168.100.2:/raid/nfs /mnt/nfs nfs rw 0 0
EOF
mount -a
ls /mnt/nfs

# Create user sshuser with UID 2027 (CHANGE NAME ETC DEPENDING ON THE TASK)
useradd -u 2027 -m sshuser

# Set password P@ssw0rd (no confirmation)
echo "sshuser:P@ssw0rd" | chpasswd

# Add to group wheel
gpasswd -a sshuser wheel

# Configure passwordless sudo
echo "sshuser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Install and enable sshd - Alt Workstation does not always ship it, and
# without it gost.sh / ansible cannot reach this host on 2027
apt-get install -y openssh-server
systemctl enable --now sshd

# Configure SSH
sed -i 's/^#\?Port .*/Port 2027/' /etc/openssh/sshd_config
grep -q "^Port 2027" /etc/openssh/sshd_config || echo "Port 2027" >> /etc/openssh/sshd_config
sed -i 's/#PermitRootLogin without-password/PermitRootLogin no/' /etc/openssh/sshd_config
echo "AllowUsers sshuser" >> /etc/openssh/sshd_config
echo "MaxAuthTries 2" >> /etc/openssh/sshd_config
echo "Banner /etc/openssh/banner" >> /etc/openssh/sshd_config

# Create banner
echo "Authorized access only" > /etc/openssh/banner

# Restart SSH so it listens on 2027
systemctl restart sshd

echo "Configuration complete:"
echo "- User: sshuser (password: P@ssw0rd)"
echo "- SSH port: 2027"
echo "- Root login disabled"
echo "- Banner created"

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
echo "=== Checking hq-cli configuration ===" | tee -a "$LOG"
check "Hostname = hq-cli.au-team.irpo"              '[ "$(hostnamectl --static)" = "hq-cli.au-team.irpo" ]'
check "Yandex Browser installed"                    'rpm -q yandex-browser-stable'
check "/mnt/nfs is mounted"                         'mountpoint -q /mnt/nfs'
check "NFS mount added to fstab"                    'grep -q "192.168.100.2:/raid/nfs /mnt/nfs nfs" /etc/fstab'
check "User sshuser created (UID 2027)"             '[ "$(id -u sshuser)" = "2027" ]'
check "sshuser is in group wheel"                   'id -nG sshuser | grep -qw wheel'
check "sshuser added to sudoers"                    'grep -q "sshuser ALL=(ALL) NOPASSWD: ALL" /etc/sudoers'
check "SSH port changed to 2027"                    'grep -q "^Port 2027" /etc/openssh/sshd_config'
check "SSH root login disabled"                     'grep -q "^PermitRootLogin no" /etc/openssh/sshd_config'
check "AllowUsers sshuser configured"               'grep -q "^AllowUsers sshuser" /etc/openssh/sshd_config'
check "MaxAuthTries 2 configured"                   'grep -q "^MaxAuthTries 2" /etc/openssh/sshd_config'
check "SSH banner created"                          '[ -f /etc/openssh/banner ]'
check "openssh-server installed"                    'rpm -q openssh-server'
check "SSH service active"                          'systemctl is-active --quiet sshd'
check "SSH enabled at boot"                         'systemctl is-enabled --quiet sshd'
check "sshd listens on port 2027"                   'ss -tln | grep -q ":2027 "'
check "chronyd active"                              'systemctl is-active --quiet chronyd'
check "chronyd enabled at boot"                     'systemctl is-enabled --quiet chronyd'
check "chrony.conf points to ISP (172.16.1.1)"     'grep -qx "server 172.16.1.1 iburst" /etc/chrony.conf'
check "Time synced from ISP (172.16.1.1)"          'chronyc -n sources | grep -q "^\^\* 172.16.1.1 "'
echo "=== Check complete, log saved to $LOG ===" | tee -a "$LOG"

# ===========================================================
# Pre-fetch gost-hqcli.sh (used much later, once gost.sh on HQ-SRV
# has delivered the CA certificate here) so it is already on disk
# when needed - do not run it yet, ca.cer does not exist until then
# ===========================================================
wget -O "$DIR/gost-hqcli.sh" "$(dirname "$RAW_URL")/gost-hqcli.sh" && chmod +x "$DIR/gost-hqcli.sh" \
    || echo "Could not pre-fetch gost-hqcli.sh, fetch it manually later" >&2

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
rm -f "$LOG" "$DIR/gost-hqcli.sh" "$DIR/retry" "$DIR/delete" "$SELF"
DELEOF
chmod +x "$DIR/delete"

rm -f "$SELF"

echo
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} NEXT STEP${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e " This is the last host on the HQ client branch."
echo -e " Nothing else to configure here for now."
echo -e " (gost-hqcli.sh was pre-fetched into this directory - run it much"
echo -e "  later, once gost.sh on HQ-SRV has delivered the CA certificate"
echo -e "  here)"
echo -e "${CYAN}============================================================${NC}"
echo
