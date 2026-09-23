#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/checks/$NAME"

WEB_FQDN="web.au-team.irpo"
DOCKER_FQDN="docker.au-team.irpo"
HQCLI_USER="sshuser"
ANCHOR="/etc/pki/ca-trust/source/anchors/ca.cer"
# nginx reverse proxy on ISP, reachable from here through HQ-RTR
PROXY_IP="172.16.1.1"
# ===========================================================

# gost.sh (on HQ-SRV) copies ca.cer into sshuser's home over scp, but
# this script is usually run as root, whose $HOME is /root
USER_HOME="$(getent passwd "$HQCLI_USER" | cut -d: -f6)"
CA_CER=""
for c in "$USER_HOME/ca.cer" "$HOME/ca.cer" "$DIR/ca.cer"; do
    if [ -s "$c" ]; then
        CA_CER="$c"
        break
    fi
done

if [ -z "$CA_CER" ]; then
    echo "ca.cer not found in $USER_HOME, $HOME or $DIR." >&2
    echo "Run gost.sh on HQ-SRV first - it copies ca.cer to $USER_HOME on this host." >&2
    exit 1
fi
echo "Using $CA_CER"

sudo cp "$CA_CER" "$ANCHOR"
sudo update-ca-trust

# The DNS on HQ-SRV has no records for the proxied sites, so point them
# at the proxy here; old lines for these names are replaced, not duplicated
for fqdn in "$WEB_FQDN" "$DOCKER_FQDN"; do
    sudo sed -i "/[[:space:]]${fqdn//./\\.}\([[:space:]]\|\$\)/d" /etc/hosts
    echo "$PROXY_IP $fqdn" | sudo tee -a /etc/hosts >/dev/null
done

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
echo "=== Checking gost-hqcli configuration ===" | tee -a "$LOG"
check "CA certificate installed as trust anchor"  "[ -s \"$ANCHOR\" ]"
check "Anchor matches the delivered CA cert"      "cmp -s \"$CA_CER\" \"$ANCHOR\""
check "update-ca-trust is available"              'command -v update-ca-trust'
check "$WEB_FQDN resolves to $PROXY_IP"           "getent hosts $WEB_FQDN | grep -q \"^$PROXY_IP \""
check "$DOCKER_FQDN resolves to $PROXY_IP"        "getent hosts $DOCKER_FQDN | grep -q \"^$PROXY_IP \""
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
echo -e " The CA is now trusted on this host."
echo -e " Open a browser here and check:"
echo -e "   https://$WEB_FQDN"
echo -e "   https://$DOCKER_FQDN"
echo -e " Neither should show a certificate warning."
echo -e "${CYAN}============================================================${NC}"
echo
