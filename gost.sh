#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/checks/$NAME"

CA_DIR="$DIR/gost-ca"
DAYS=30

CA_KEY="$CA_DIR/ca.key"
CA_CER="$CA_DIR/ca.cer"
CA_SUBJ="/C=RU/ST=Krasnoyarsk/O=AU-TEAM/CN=AU-TEAM Root CA"

WEB_FQDN="web.au-team.irpo"
DOCKER_FQDN="docker.au-team.irpo"

ISP_USER="root"
ISP_HOST="172.16.1.1"

HQCLI_USER="sshuser"
HQCLI_HOST="192.168.200.2"
HQCLI_PORT=2027

SSH_PASSWORD="P@ssw0rd"
# ===========================================================

mkdir -p "$CA_DIR"
cd "$CA_DIR" || exit 1

# Install GOST support for OpenSSL
apt-get install -y openssl-gost-engine

# Enable the GOST engine system-wide
control openssl-gost enabled

# Sanity check: the engine must actually be able to produce a GOST key
if ! openssl genpkey -algorithm gost2012_256 -pkeyopt paramset:A -out /dev/null 2>/dev/null; then
    echo "GOST engine is not active, aborting" >&2
    exit 1
fi

# 1. Root CA key + self-signed certificate (30 days)
openssl genpkey -algorithm gost2012_256 -pkeyopt paramset:TCB -out "$CA_KEY"
openssl req -new -x509 -md_gost12_256 -days "$DAYS" -key "$CA_KEY" -subj "$CA_SUBJ" -out "$CA_CER"
chmod 600 "$CA_KEY"

# 2. Per-host keys
openssl genpkey -algorithm gost2012_256 -pkeyopt paramset:A -out "$WEB_FQDN.key"
openssl genpkey -algorithm gost2012_256 -pkeyopt paramset:A -out "$DOCKER_FQDN.key"
chmod 600 "$WEB_FQDN.key" "$DOCKER_FQDN.key"

# 3. CSRs, each with its own SAN - without it Chromium-based browsers
#    reject the certificate even when the CN matches
openssl req -new -md_gost12_256 -key "$WEB_FQDN.key" \
    -subj "/C=RU/O=AU-TEAM/CN=$WEB_FQDN" \
    -addext "subjectAltName=DNS:$WEB_FQDN" \
    -out "$WEB_FQDN.csr"

openssl req -new -md_gost12_256 -key "$DOCKER_FQDN.key" \
    -subj "/C=RU/O=AU-TEAM/CN=$DOCKER_FQDN" \
    -addext "subjectAltName=DNS:$DOCKER_FQDN" \
    -out "$DOCKER_FQDN.csr"

# 4. Sign both CSRs with our CA, carrying the SAN extension over.
#    x509 -req never copies CSR extensions on its own; -copy_extensions
#    only exists on OpenSSL 3.0+, so an extfile is used instead - it
#    works the same way on both 1.1.1 and 3.x.
printf 'subjectAltName=DNS:%s\n' "$WEB_FQDN" > "$WEB_FQDN.extfile"
printf 'subjectAltName=DNS:%s\n' "$DOCKER_FQDN" > "$DOCKER_FQDN.extfile"

openssl x509 -req -in "$WEB_FQDN.csr" -CA "$CA_CER" -CAkey "$CA_KEY" -CAcreateserial \
    -md_gost12_256 -days "$DAYS" -extfile "$WEB_FQDN.extfile" \
    -out "$WEB_FQDN.cer"

openssl x509 -req -in "$DOCKER_FQDN.csr" -CA "$CA_CER" -CAkey "$CA_KEY" -CAcreateserial \
    -md_gost12_256 -days "$DAYS" -extfile "$DOCKER_FQDN.extfile" \
    -out "$DOCKER_FQDN.cer"

echo "Certificates generated in $CA_DIR"

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
echo "=== Checking gost configuration ===" | tee -a "$LOG"
check "openssl-gost-engine installed"                'rpm -q openssl-gost-engine'
check "GOST engine produces keys"                    "openssl genpkey -algorithm gost2012_256 -pkeyopt paramset:A -out /dev/null"
check "CA key exists"                                "[ -s \"$CA_KEY\" ]"
check "CA certificate exists"                        "[ -s \"$CA_CER\" ]"
check "CA certificate is self-signed"                "openssl verify -CAfile \"$CA_CER\" \"$CA_CER\""
check "$WEB_FQDN key exists"                         "[ -s \"$CA_DIR/$WEB_FQDN.key\" ]"
check "$WEB_FQDN certificate exists"                 "[ -s \"$CA_DIR/$WEB_FQDN.cer\" ]"
check "$WEB_FQDN certificate signed by our CA"       "openssl verify -CAfile \"$CA_CER\" \"$CA_DIR/$WEB_FQDN.cer\""
check "$WEB_FQDN certificate has correct SAN"        "openssl x509 -in \"$CA_DIR/$WEB_FQDN.cer\" -noout -text | grep -q \"DNS:$WEB_FQDN\""
check "$DOCKER_FQDN key exists"                      "[ -s \"$CA_DIR/$DOCKER_FQDN.key\" ]"
check "$DOCKER_FQDN certificate exists"              "[ -s \"$CA_DIR/$DOCKER_FQDN.cer\" ]"
check "$DOCKER_FQDN certificate signed by our CA"    "openssl verify -CAfile \"$CA_CER\" \"$CA_DIR/$DOCKER_FQDN.cer\""
check "$DOCKER_FQDN certificate has correct SAN"     "openssl x509 -in \"$CA_DIR/$DOCKER_FQDN.cer\" -noout -text | grep -q \"DNS:$DOCKER_FQDN\""
echo "=== Check complete, log saved to $LOG ===" | tee -a "$LOG"

# ===========================================================
# Deliver the certificates
# ===========================================================
for f in "$WEB_FQDN.key" "$WEB_FQDN.cer" "$DOCKER_FQDN.key" "$DOCKER_FQDN.cer" "$(basename "$CA_CER")"; do
    if [ ! -s "$CA_DIR/$f" ]; then
        echo "Certificate generation failed, $CA_DIR/$f is missing - not copying anything to ISP/HQ-CLI. See the check output above." >&2
        exit 1
    fi
done

echo "Copying $WEB_FQDN and $DOCKER_FQDN key/cert pairs to ISP ($ISP_HOST):"
echo -e "${YELLOW}Username: $ISP_USER${NC}"
echo -e "${YELLOW}Password: $SSH_PASSWORD${NC}"
scp "$CA_DIR/$WEB_FQDN.key" "$CA_DIR/$WEB_FQDN.cer" "$CA_DIR/$DOCKER_FQDN.key" "$CA_DIR/$DOCKER_FQDN.cer" "$ISP_USER@$ISP_HOST:~/"

echo "Copying the CA root certificate to HQ-CLI ($HQCLI_HOST):"
echo -e "${YELLOW}Username: $HQCLI_USER${NC}"
echo -e "${YELLOW}Password: $SSH_PASSWORD${NC}"
scp -P "$HQCLI_PORT" "$CA_CER" "$HQCLI_USER@$HQCLI_HOST:~/"

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
# Removes everything created by $NAME in this directory, including the CA
rm -rf "$LOG" "$CA_DIR" "$DIR/retry" "$DIR/delete" "$SELF"
DELEOF
chmod +x "$DIR/delete"

rm -f "$SELF"

echo
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} NEXT STEP${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e " Run next : ${YELLOW}gost-isp.sh${NC} on ISP, then ${YELLOW}gost-hqcli.sh${NC} on HQ-CLI"
echo -e " Both hosts already have the key/cert files (delivered by this"
echo -e " script, just now) and gost-isp.sh / gost-hqcli.sh itself"
echo -e " (pre-fetched back when isp.sh / HQ-CLI.sh were first run)"
echo -e " sitting in the same directory - just run:"
echo
echo -e "   On ISP:     ./gost-isp.sh"
echo -e "   On HQ-CLI:  ./gost-hqcli.sh"
echo
echo -e " If either file is missing there, fetch it again:"
echo -e "   wget -O gost-isp.sh   $(dirname "$RAW_URL")/gost-isp.sh"
echo -e "   wget -O gost-hqcli.sh $(dirname "$RAW_URL")/gost-hqcli.sh"
echo -e "${CYAN}============================================================${NC}"
echo
