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

# How VLAN 200 reaches HQ-CLI: "proxmox" or "manual". By default the answer
# hq-rtr.sh saved next to it; VLAN_MODE=... overrides, empty = ask
VLAN_MODE="${VLAN_MODE:-$(cat "$DIR/vlan-mode" 2>/dev/null)}"
# ===========================================================

sed -i 's/^dhcp-option=6,77\.88\.8\.8$/dhcp-option=6,192.168.100.2/' /etc/dnsmasq.conf

echo "Change 77.88.8.8 to 192.168.100.2"

# dnsmasq only reads its config at start
systemctl restart dnsmasq

# ===========================================================
# Point DNS at HQ-SRV - done last, everything above still needs
# the public resolver
# ===========================================================
cat > /etc/net/ifaces/enp7s1/resolv.conf <<EOF
nameserver 192.168.100.2
search tkhis.pro
EOF
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
echo "=== Checking HQ-RTR-2 configuration ===" | tee -a "$LOG"
check "dhcp-option=6 points to 192.168.100.2"       'grep -q "^dhcp-option=6,192.168.100.2$" /etc/dnsmasq.conf'
check "Old value 77.88.8.8 no longer set"           '! grep -q "^dhcp-option=6,77.88.8.8$" /etc/dnsmasq.conf'
check "dnsmasq is running"                          'systemctl is-active --quiet dnsmasq'
check "DNS on enp7s1: 192.168.100.2, search tkhis.pro" 'grep -qx "nameserver 192.168.100.2" /etc/net/ifaces/enp7s1/resolv.conf && grep -qx "search tkhis.pro" /etc/net/ifaces/enp7s1/resolv.conf'
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
rm -f "$LOG" "$NEXT" "$DIR/retry" "$DIR/delete" "$DIR/hq-cli-steps" "$SELF"
DELEOF
chmod +x "$DIR/delete"

rm -f "$SELF"

# ===========================================================
# NEXT STEP depends on how VLAN 200 reaches HQ-CLI. The steps are
# saved as ./hq-cli-steps, so a wrong choice is fixed with
# "./hq-cli-steps manual" or "./hq-cli-steps proxmox"
# ===========================================================
cat > "$DIR/hq-cli-steps" <<'STEPSEOF'
#!/bin/bash
# Prints how to bring HQ-CLI onto VLAN 200: hq-cli-steps proxmox|manual
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
NC='\033[0m'
LINE="${CYAN}============================================================${NC}"

echo
echo -e "$LINE"
echo -e "${CYAN} NEXT STEP${NC}"
echo -e "$LINE"
echo -e " Run next : ${YELLOW}hq-cli.sh${NC} on the HQ client"
if [ "$1" = "manual" ]; then
    echo -e " Segment  : VLAN 200, 192.168.200.0/28 (DHCP) - ${YELLOW}the VM tags it${NC} (enp7s1.200)"
    echo
    echo -e " Proxmox: no VLAN tag on the HQ-CLI NIC. Inside HQ-CLI (NetworkManager):"
    echo    "   nmcli con add type vlan con-name enp7s1.200 ifname enp7s1.200 dev enp7s1 id 200 ipv4.method auto"
    echo    "   nmcli con up enp7s1.200"
    echo -e " Or, if HQ-CLI runs etcnet instead of NetworkManager:"
    echo    "   mkdir -p /etc/net/ifaces/enp7s1.200"
    echo    "   printf '%s\n' TYPE=vlan HOST=enp7s1 VID=200 BOOTPROTO=dhcp > /etc/net/ifaces/enp7s1.200/options"
    echo    "   sed -i 's/^BOOTPROTO=.*/BOOTPROTO=static/' /etc/net/ifaces/enp7s1/options"
    echo    "   systemctl restart network"
    echo -e " Then: ip -br addr show enp7s1.200   -> 192.168.200.x/28 from this router"
    OTHER="proxmox"
else
    echo -e " Segment  : VLAN 200, 192.168.200.0/28 (DHCP) - ${YELLOW}Proxmox tags it${NC}"
    echo
    echo -e " Proxmox: the HQ-CLI NIC has VLAN Tag=200. Nothing to set by hand"
    echo -e " inside HQ-CLI: address, gateway and, as of this change, the internal"
    echo -e " DNS server come from this router's DHCP on enp7s1."
    echo -e " If HQ-CLI already holds a lease, renew it there first:"
    echo    "   systemctl restart network"
    OTHER="manual"
fi
echo -e " Other scenario: ${YELLOW}./hq-cli-steps $OTHER${NC}"
echo -e "$LINE"
echo
STEPSEOF
chmod +x "$DIR/hq-cli-steps"

# Ask how VLAN 200 reaches HQ-CLI, unless VLAN_MODE already says so
# (hq-rtr.sh saved its answer). Enter, or no terminal at all, means proxmox
choose_vlan_mode() {
    local ans
    case "$VLAN_MODE" in proxmox|manual) return ;; esac
    VLAN_MODE="proxmox"
    { : </dev/tty; } 2>/dev/null || return
    echo
    echo -e "${CYAN} How does HQ-CLI get VLAN 200?${NC}"
    echo -e "   1) Proxmox tags it: its NIC has VLAN Tag=200 (default)"
    echo -e "   2) The VM tags it: no tag on its NIC, enp7s1.200 inside"
    while true; do
        read -r -p " Choice [1]: " ans </dev/tty
        case "$ans" in
            ""|1) VLAN_MODE="proxmox"; return ;;
            2)    VLAN_MODE="manual";  return ;;
        esac
    done
}
choose_vlan_mode

"$DIR/hq-cli-steps" "$VLAN_MODE"
# Same text without colours, for later: cat <script>-next-step.txt
"$DIR/hq-cli-steps" "$VLAN_MODE" | sed 's/\x1b\[[0-9;]*m//g' > "$NEXT"
echo -e " ${CYAN}(saved: cat $(basename "$NEXT"))${NC}"
