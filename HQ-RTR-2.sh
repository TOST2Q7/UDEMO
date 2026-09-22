#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/checks/$NAME"
# ===========================================================

sed -i 's/^dhcp-option=6,77\.88\.8\.8$/dhcp-option=6,192.168.100.2/' /etc/dnsmasq.conf

echo "Change 77.88.8.8 to 192.168.100.2"

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
echo "=== Checking HQ-RTR-2 configuration ===" | tee -a "$LOG"
check "dhcp-option=6 points to 192.168.100.2"       'grep -q "^dhcp-option=6,192.168.100.2$" /etc/dnsmasq.conf'
check "Old value 77.88.8.8 no longer set"           '! grep -q "^dhcp-option=6,77.88.8.8$" /etc/dnsmasq.conf'
check "dnsmasq is running"                          'systemctl is-active --quiet dnsmasq'
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
rm -f "$LOG" "$DIR/retry" "$DIR/delete" "$SELF"
DELEOF
chmod +x "$DIR/delete"

rm -f "$SELF"

echo
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} NEXT STEP${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e " Run next : ${YELLOW}HQ-CLI.sh${NC} on the HQ client"
echo -e " Segment  : VLAN 200, 192.168.200.0/28 (DHCP)"
echo
echo -e " No manual network setup is needed on that host - it gets an"
echo -e " address, gateway and, as of this change, the correct internal"
echo -e " DNS server automatically via DHCP from this router."
echo -e "${CYAN}============================================================${NC}"
echo
