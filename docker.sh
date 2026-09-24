#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/checks/$NAME"

# Runs on BR-SRV. ISP proxies docker.au-team.irpo to BR-RTR:8080,
# which br-rtr.sh forwards here
ISO_DEV="/dev/sr0"
ISO_MNT="/mnt"
COMPOSE_DIR="/opt/testapp"
APP_PORT="8080"
DB_NAME="testdb"
DB_USER="testc"
DB_PASS="P@ssw0rd"
DB_ROOT_PASS="toor"
# ===========================================================

apt-get update
apt-get install -y docker-engine docker-compose-v2 curl

systemctl enable --now docker.service

# The exam ISO carries the images; mount it unless it already is
mkdir -p "$ISO_MNT"
mountpoint -q "$ISO_MNT" || mount "$ISO_DEV" "$ISO_MNT"
if [ ! -d "$ISO_MNT/docker" ]; then
    echo "$ISO_MNT/docker not found - is the exam ISO attached as $ISO_DEV?" >&2
fi

# Load an image tarball and print the tag it was saved under, so the
# compose file uses exactly what is on disk and never tries to pull
load_image() {
    docker load -i "$1" | sed -n 's/^Loaded image: //p' | tail -n 1
}
APP_IMAGE="$(load_image "$ISO_MNT/docker/site_latest.tar")"
DB_IMAGE="$(load_image "$ISO_MNT/docker/mariadb_latest.tar")"
APP_IMAGE="${APP_IMAGE:-site:latest}"
DB_IMAGE="${DB_IMAGE:-mariadb:latest}"
echo "App image: $APP_IMAGE"
echo "DB image : $DB_IMAGE"

mkdir -p "$COMPOSE_DIR"
cat > "$COMPOSE_DIR/compose.yaml" <<EOF
services:
  database:
    container_name: db
    image: $DB_IMAGE
    restart: always
    ports:
      - "3306:3306"
    environment:
      MARIADB_DATABASE: "$DB_NAME"
      MARIADB_USER: "$DB_USER"
      MARIADB_PASSWORD: "$DB_PASS"
      MARIADB_ROOT_PASSWORD: "$DB_ROOT_PASS"

  app:
    container_name: testapp
    image: $APP_IMAGE
    restart: always
    ports:
      - "$APP_PORT:8000"
    environment:
      DB_TYPE: "maria"
      DB_HOST: "database"
      DB_PORT: "3306"
      DB_NAME: "$DB_NAME"
      DB_USER: "$DB_USER"
      DB_PASS: "$DB_PASS"
    depends_on:
      - database
EOF

docker compose -f "$COMPOSE_DIR/compose.yaml" up -d

# The app answers only once MariaDB has initialised - give it a minute
for i in $(seq 30); do
    curl -s -o /dev/null "http://127.0.0.1:$APP_PORT" && break
    sleep 2
done

docker compose -f "$COMPOSE_DIR/compose.yaml" ps

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
echo "=== Checking docker configuration ===" | tee -a "$LOG"
check "docker is running"                           'systemctl is-active --quiet docker'
check "docker enabled at boot"                      'systemctl is-enabled --quiet docker'
check "docker compose plugin available"             'docker compose version'
check "Image $APP_IMAGE loaded"                     "docker image inspect \"$APP_IMAGE\""
check "Image $DB_IMAGE loaded"                      "docker image inspect \"$DB_IMAGE\""
check "compose.yaml in $COMPOSE_DIR"                "[ -s \"$COMPOSE_DIR/compose.yaml\" ]"
check "Container db is running"                     '[ "$(docker inspect -f "{{.State.Running}}" db)" = "true" ]'
check "Container testapp is running"                '[ "$(docker inspect -f "{{.State.Running}}" testapp)" = "true" ]'
check "db restart policy = always"                  '[ "$(docker inspect -f "{{.HostConfig.RestartPolicy.Name}}" db)" = "always" ]'
check "testapp restart policy = always"             '[ "$(docker inspect -f "{{.HostConfig.RestartPolicy.Name}}" testapp)" = "always" ]'
check "App answers on port $APP_PORT"               "curl -s -o /dev/null http://127.0.0.1:$APP_PORT"
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
# (the containers and $COMPOSE_DIR stay)
rm -f "$LOG" "$DIR/retry" "$DIR/delete" "$SELF"
DELEOF
chmod +x "$DIR/delete"

rm -f "$SELF"

echo
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} NEXT STEP${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e " testapp is up on this host, port $APP_PORT."
echo -e " BR-RTR forwards 172.16.2.2:$APP_PORT here. Once ${YELLOW}web.sh${NC} has run"
echo -e " on HQ-SRV too, run ${YELLOW}proxy.sh${NC} on ISP (the nginx reverse proxy for"
echo -e " web.au-team.irpo and docker.au-team.irpo). isp.sh pre-fetched it;"
echo -e " if it is not there:"
echo -e "   wget -O proxy.sh $(dirname "$RAW_URL")/proxy.sh && bash proxy.sh"
echo -e " Manage the stack with:"
echo -e "   docker compose -f $COMPOSE_DIR/compose.yaml ps|logs|restart"
echo -e "${CYAN}============================================================${NC}"
echo

exec bash
