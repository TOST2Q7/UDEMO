#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/checks/$NAME"

# Runs on ISP. Plain-HTTP reverse proxy; gost-isp.sh later rewrites
# the same vhost file for HTTPS and reuses the same .htpasswd
WEB_FQDN="web.au-team.irpo"
DOCKER_FQDN="docker.au-team.irpo"
# web.sh on HQ-SRV, reached through HQ-RTR's DNAT
WEB_BACKEND="172.16.1.2:8080"
# docker.sh on BR-SRV, reached through BR-RTR's DNAT
DOCKER_BACKEND="172.16.2.2:8080"
VHOST="/etc/nginx/sites-available.d/default.conf"
HTPASSWD="/etc/nginx/.htpasswd"
AUTH_USER="WEB"
AUTH_PASS="P@ssw0rd"
# ===========================================================

apt-get update
apt-get install -y nginx apache2-htpasswd curl

htpasswd -bc "$HTPASSWD" "$AUTH_USER" "$AUTH_PASS"

cat > "$VHOST" <<NGINXEOF
server {
    listen 80;
    server_name $WEB_FQDN;

    location / {
        proxy_pass http://$WEB_BACKEND;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        auth_basic "Restricted area";
        auth_basic_user_file $HTPASSWD;
    }
}

server {
    listen 80;
    server_name $DOCKER_FQDN;

    location / {
        proxy_pass http://$DOCKER_BACKEND;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXEOF

ln -sf "$VHOST" /etc/nginx/sites-enabled.d/

nginx -t
systemctl enable --now nginx
systemctl restart nginx

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

# HTTP status of a request to this proxy for the given Host header
status() {
    curl -s -o /dev/null -w "%{http_code}" -H "Host: $1" "${@:2}" http://127.0.0.1/
}

: > "$LOG"
echo "=== Checking proxy configuration ===" | tee -a "$LOG"
check "nginx installed"                             'rpm -q nginx'
check "$HTPASSWD has user $AUTH_USER"               "grep -q \"^$AUTH_USER:\" \"$HTPASSWD\""
check "vhost enabled"                               "[ -L /etc/nginx/sites-enabled.d/$(basename "$VHOST") ]"
check "nginx config test passes"                    'nginx -t'
check "nginx is running"                            'systemctl is-active --quiet nginx'
check "nginx enabled at boot"                       'systemctl is-enabled --quiet nginx'
check "$WEB_FQDN asks for a password (401)"         "[ \"\$(status $WEB_FQDN)\" = \"401\" ]"
check "$WEB_FQDN opens with $AUTH_USER (200)"       "[ \"\$(status $WEB_FQDN -u '$AUTH_USER:$AUTH_PASS')\" = \"200\" ]"
check "$DOCKER_FQDN opens (200)"                    "[ \"\$(status $DOCKER_FQDN)\" = \"200\" ]"
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
echo -e " The HTTP reverse proxy is up:"
echo -e "   http://$WEB_FQDN    -> $WEB_BACKEND (login $AUTH_USER / $AUTH_PASS)"
echo -e "   http://$DOCKER_FQDN -> $DOCKER_BACKEND"
echo -e " A 502 on either means its backend is not up yet (web.sh / docker.sh)."
echo -e " For HTTPS: ${YELLOW}gost.sh${NC} on HQ-SRV, then ${YELLOW}gost-isp.sh${NC} here"
echo -e " (pre-fetched by isp.sh), then ${YELLOW}gost-hqcli.sh${NC} on HQ-CLI."
echo -e "${CYAN}============================================================${NC}"
echo

exec bash
