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
WEB_BACKEND="172.16.1.2:8080"
DOCKER_BACKEND="172.16.2.2:8080"
SSL_DIR="/etc/nginx/ssl"
VHOST="/etc/nginx/sites-available.d/default.conf"
CERT_SRC="$HOME"
# ===========================================================

# The key/cert files are expected to already be here, delivered by
# gost.sh (run on HQ-SRV) via scp
for f in "$WEB_FQDN.key" "$WEB_FQDN.cer" "$DOCKER_FQDN.key" "$DOCKER_FQDN.cer"; do
    if [ ! -s "$CERT_SRC/$f" ]; then
        echo "Missing $CERT_SRC/$f - run gost.sh on HQ-SRV first, it delivers these files here." >&2
        exit 1
    fi
done

# Install GOST support for OpenSSL - nginx links against the same libssl
apt-get install -y openssl-gost-engine
control openssl-gost enabled

mkdir -p "$SSL_DIR"
cp "$CERT_SRC/$WEB_FQDN.key" "$CERT_SRC/$WEB_FQDN.cer" "$CERT_SRC/$DOCKER_FQDN.key" "$CERT_SRC/$DOCKER_FQDN.cer" "$SSL_DIR/"

# Switch the reverse proxy from HTTP to HTTPS
cat > "$VHOST" <<NGINXEOF
server {
    listen 443 ssl;
    server_name $WEB_FQDN;

    ssl_certificate     $SSL_DIR/$WEB_FQDN.cer;
    ssl_certificate_key $SSL_DIR/$WEB_FQDN.key;

    location / {
        proxy_pass http://$WEB_BACKEND;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        auth_basic "Restricted area";
        auth_basic_user_file /etc/nginx/.htpasswd;
    }
}

server {
    listen 443 ssl;
    server_name $DOCKER_FQDN;

    ssl_certificate     $SSL_DIR/$DOCKER_FQDN.cer;
    ssl_certificate_key $SSL_DIR/$DOCKER_FQDN.key;

    location / {
        proxy_pass http://$DOCKER_BACKEND;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXEOF

nginx -t && systemctl restart nginx

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
echo "=== Checking gost-isp configuration ===" | tee -a "$LOG"
check "openssl-gost-engine installed"          'rpm -q openssl-gost-engine'
check "$WEB_FQDN key/cert copied to $SSL_DIR"  "[ -s \"$SSL_DIR/$WEB_FQDN.key\" ] && [ -s \"$SSL_DIR/$WEB_FQDN.cer\" ]"
check "$DOCKER_FQDN key/cert copied to $SSL_DIR" "[ -s \"$SSL_DIR/$DOCKER_FQDN.key\" ] && [ -s \"$SSL_DIR/$DOCKER_FQDN.cer\" ]"
check "vhost points at the right $WEB_FQDN files"    "grep -q \"$SSL_DIR/$WEB_FQDN.key\" \"$VHOST\" && grep -q \"$SSL_DIR/$WEB_FQDN.cer\" \"$VHOST\""
check "vhost points at the right $DOCKER_FQDN files" "grep -q \"$SSL_DIR/$DOCKER_FQDN.key\" \"$VHOST\" && grep -q \"$SSL_DIR/$DOCKER_FQDN.cer\" \"$VHOST\""
check "nginx config test passes"               'nginx -t'
check "nginx service active"                   'systemctl is-active --quiet nginx'
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
echo -e " HTTPS is live on this proxy. Nothing else to do here."
echo -e " Now run gost-hqcli.sh on HQ-CLI to trust the CA there, then"
echo -e " check https://$WEB_FQDN and https://$DOCKER_FQDN in its browser."
echo -e "${CYAN}============================================================${NC}"
echo
