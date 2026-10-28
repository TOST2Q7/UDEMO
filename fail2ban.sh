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

# Runs on HQ-SRV: fail2ban guards SSH on 2127 - 3 failed logins within
# 10 minutes ban the address for 1 minute
JAIL="/etc/fail2ban/jail.conf"
SSH_PORT=2127
# ===========================================================

apt-get update
apt-get install -y fail2ban python3-module-systemd

# ALT logs sshd to the journal, not to a file: use the systemd paths
sed -i 's/before = paths-altlinux.conf/before = paths-altlinux-systemd.conf/' "$JAIL"

# Turn on the [sshd] jail with our port and limits; skipped on a rerun so
# the lines are not added twice
if ! sed -n '/^\[sshd\]/,/^\[/p' "$JAIL" | grep -qx "enabled = true"; then
    sed -i '/^\[sshd\]/a\enabled = true' "$JAIL"
    sed -i "/^\[sshd\]/,/^\[/{s/^port.*/port    = $SSH_PORT/}" "$JAIL"
    sed -i "/^\[sshd\]/,/^\[/s/port.*$SSH_PORT/&\nmaxretry = 3/" "$JAIL"
    sed -i '/^\[sshd\]/,/^\[/s/maxretry.*3/&\nfindtime = 10m/' "$JAIL"
    sed -i '/^\[sshd\]/,/^\[/s/findtime.*10m/&\nbantime = 1m/' "$JAIL"
fi

systemctl enable --now fail2ban
systemctl restart fail2ban

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

# The [sshd] section of jail.conf
sshd_jail() {
    sed -n '/^\[sshd\]/,/^\[/p' "$JAIL"
}

# fail2ban needs a moment after the restart before the jail answers
for i in $(seq 10); do
    fail2ban-client status sshd &>/dev/null && break
    sleep 1
done

: > "$LOG"
echo "=== Checking fail2ban configuration ===" | tee -a "$LOG"
check "fail2ban installed"                          'rpm -q fail2ban'
check "jail.conf uses the systemd paths"            "grep -q '^before = paths-altlinux-systemd.conf' $JAIL"
check "[sshd] jail enabled"                         'sshd_jail | grep -qx "enabled = true"'
check "[sshd] port = $SSH_PORT"                     "sshd_jail | grep -qE '^port +=  *$SSH_PORT$'"
check "[sshd] maxretry = 3"                         'sshd_jail | grep -qx "maxretry = 3"'
check "[sshd] findtime = 10m"                       'sshd_jail | grep -qx "findtime = 10m"'
check "[sshd] bantime = 1m"                         'sshd_jail | grep -qx "bantime = 1m"'
check "fail2ban is running"                         'systemctl is-active --quiet fail2ban'
check "fail2ban enabled at boot"                    'systemctl is-enabled --quiet fail2ban'
check "sshd jail is active"                         'fail2ban-client status sshd'
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
# (fail2ban and its jail.conf changes stay)
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
    echo -e " fail2ban guards SSH on port $SSH_PORT. To see it work, from another"
    echo -e " host enter a wrong password 3 times:"
    echo -e "   ssh -p $SSH_PORT userssh@192.168.100.2"
    echo -e " then here: ${YELLOW}fail2ban-client status sshd${NC} lists the banned address"
    echo -e " for 1 minute."
    echo -e "${CYAN}============================================================${NC}"
    echo
}
next_step
# Same text without colours, for later: cat <script>-next-step.txt
next_step | sed 's/\x1b\[[0-9;]*m//g' > "$NEXT"
echo -e " ${CYAN}(saved: cat $(basename "$NEXT"))${NC}"

exec bash
