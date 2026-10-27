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

# Runs on the host the task names: atop writes a snapshot of the system
# every 7 minutes and keeps 28 days of them
ATOP_CONF="/etc/default/atop"
ATOP_LOGS="/var/log/atop"
# ===========================================================

apt-get update
apt-get install -y atop

# Config first, then start: atop reads it only when it starts
cat > "$ATOP_CONF" <<EOF
LOGOPTS="-R"
LOGINTERVAL=420
LOGGENERATIONS=28
LOGPATH=$ATOP_LOGS
EOF
systemctl enable --now atop
systemctl restart atop

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
echo "=== Checking atop configuration ===" | tee -a "$LOG"
check "atop installed"                              'rpm -q atop'
check "Snapshot every 7 minutes (LOGINTERVAL=420)"  "grep -qx 'LOGINTERVAL=420' $ATOP_CONF"
check "28 days kept (LOGGENERATIONS=28)"            "grep -qx 'LOGGENERATIONS=28' $ATOP_CONF"
check "atop is running"                             'systemctl is-active --quiet atop'
check "atop enabled at boot"                        'systemctl is-enabled --quiet atop'
check "Log directory $ATOP_LOGS exists"             "[ -d $ATOP_LOGS ]"
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
# (atop and its logs stay)
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
    echo -e " atop logs to $ATOP_LOGS. Replay a day's snapshots with:"
    echo -e "   ${YELLOW}atop -r $ATOP_LOGS/atop_\$(date +%Y%m%d)${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo
}
next_step
# Same text without colours, for later: cat <script>-next-step.txt
next_step | sed 's/\x1b\[[0-9;]*m//g' > "$NEXT"
echo -e " ${CYAN}(saved: cat $(basename "$NEXT"))${NC}"

exec bash
