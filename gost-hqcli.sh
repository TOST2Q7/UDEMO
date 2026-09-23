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
