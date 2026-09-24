#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/checks/$NAME"

# Runs on HQ-SRV. ISP proxies web.au-team.irpo to HQ-RTR:8080,
# which hq-rtr.sh forwards to port 80 here
ISO_DEV="/dev/sr0"
ISO_MNT="/mnt"
WEB_ROOT="/var/www/html"
DB_NAME="webdb"
DB_USER="web1"
DB_PASS="P@ssw0rd"
# ===========================================================

apt-get update
apt-get install -y lamp-server curl

# The exam ISO carries the site and the database dump; mount it unless it already is
mkdir -p "$ISO_MNT"
mountpoint -q "$ISO_MNT" || mount "$ISO_DEV" "$ISO_MNT"
if [ ! -d "$ISO_MNT/web" ]; then
    echo "$ISO_MNT/web not found - is the exam ISO attached as $ISO_DEV?" >&2
fi

cp "$ISO_MNT/web/index.php" "$ISO_MNT/web/logo.png" "$WEB_ROOT/"
# Apache's default placeholder would win over index.php
rm -f "$WEB_ROOT/index.html"

# Point the site at our database credentials
sed -i "s/\$username = \"user\";/\$username = \"$DB_USER\";/" "$WEB_ROOT/index.php"
sed -i "s/\$password = \"password\";/\$password = \"$DB_PASS\";/" "$WEB_ROOT/index.php"
sed -i "s/\$dbname = \"db\";/\$dbname = \"$DB_NAME\";/" "$WEB_ROOT/index.php"

systemctl enable --now mariadb

mariadb -u root <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

# Import the dump only into an empty database, so a rerun does not
# trip over tables that already exist
if [ -z "$(mariadb -u "$DB_USER" -p"$DB_PASS" -N -e 'SHOW TABLES' "$DB_NAME")" ]; then
    mariadb -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$ISO_MNT/web/dump.sql"
fi
mariadb -u "$DB_USER" -p"$DB_PASS" -e 'SHOW TABLES' "$DB_NAME"

systemctl enable --now httpd2
systemctl restart httpd2

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
echo "=== Checking web configuration ===" | tee -a "$LOG"
check "index.php copied to $WEB_ROOT"               "[ -s \"$WEB_ROOT/index.php\" ]"
check "logo.png copied to $WEB_ROOT"                "[ -s \"$WEB_ROOT/logo.png\" ]"
check "index.php uses user $DB_USER"                "grep -q '\$username = \"$DB_USER\";' \"$WEB_ROOT/index.php\""
check "index.php uses database $DB_NAME"            "grep -q '\$dbname = \"$DB_NAME\";' \"$WEB_ROOT/index.php\""
check "mariadb is running"                          'systemctl is-active --quiet mariadb'
check "mariadb enabled at boot"                     'systemctl is-enabled --quiet mariadb'
check "$DB_USER can log in to $DB_NAME"             "mariadb -u \"$DB_USER\" -p\"$DB_PASS\" -e 'SELECT 1' \"$DB_NAME\""
check "Dump imported into $DB_NAME"                 "[ -n \"\$(mariadb -u \"$DB_USER\" -p\"$DB_PASS\" -N -e 'SHOW TABLES' \"$DB_NAME\")\" ]"
check "httpd2 is running"                           'systemctl is-active --quiet httpd2'
check "httpd2 enabled at boot"                      'systemctl is-enabled --quiet httpd2'
check "Site answers 200 on port 80"                 '[ "$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/)" = "200" ]'
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
# (the site in $WEB_ROOT and the $DB_NAME database stay)
rm -f "$LOG" "$DIR/retry" "$DIR/delete" "$SELF"
DELEOF
chmod +x "$DIR/delete"

rm -f "$SELF"

echo
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} NEXT STEP${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e " The site is up on this host, port 80."
echo -e " HQ-RTR forwards 172.16.1.2:8080 here. Once ${YELLOW}docker.sh${NC} has run"
echo -e " on BR-SRV too, run ${YELLOW}proxy.sh${NC} on ISP (the nginx reverse proxy for"
echo -e " web.au-team.irpo and docker.au-team.irpo)."
echo -e "${CYAN}============================================================${NC}"
echo

exec bash
