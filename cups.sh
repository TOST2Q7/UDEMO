#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/checks/$NAME"

# Runs on HQ-SRV: CUPS print server with the cups-pdf virtual printer,
# shared to the network
# ===========================================================

apt-get update
apt-get install -y cups cups-pdf
systemctl enable --now cups
# Share the printers and accept clients from any network
cupsctl --share-printers --remote-any
systemctl restart cups

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
echo "=== Checking cups configuration ===" | tee -a "$LOG"
check "cups installed"                              'rpm -q cups'
check "cups-pdf installed"                          'rpm -q cups-pdf'
check "cups is running"                             'systemctl is-active --quiet cups'
check "cups enabled at boot"                        'systemctl is-enabled --quiet cups'
check "Printers shared"                             'cupsctl | grep -qx "_share_printers=1"'
check "Clients from any network allowed"            'cupsctl | grep -qx "_remote_any=1"'
check "CUPS listens on port 631"                    'ss -ltn | grep -q ":631 "'
check "A printer is configured (lpstat -p)"         'lpstat -p | grep -q "^printer "'
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
# (CUPS and its printers stay)
rm -f "$LOG" "$DIR/retry" "$DIR/delete" "$SELF"
DELEOF
chmod +x "$DIR/delete"

rm -f "$SELF"

echo
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} NEXT STEP${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e " The print server is up. ${YELLOW}lpstat -p${NC} here shows the printer name;"
echo -e " on HQ-CLI add it as:"
echo -e "   ipp://hq-srv.au-team.irpo:631/printers/<name>"
echo -e "${CYAN}============================================================${NC}"
echo

exec bash
