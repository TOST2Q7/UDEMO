#!/bin/bash
# ===========================================================
# Variables
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
NAME="$(basename "$SELF")"
LOG="$DIR/${NAME%.sh}-check.log"
RAW_URL="https://raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/checks/$NAME"

# Runs on BR-SRV after samba.sh: imports the users from Users.csv on the
# exam ISO into the domain, each OU from the CSV becomes an OU in AD
ISO_DEV="/dev/sr0"
ISO_MNT="/mnt"
CSV="$ISO_MNT/Users.csv"
IMPORT="$DIR/import_user.sh"
# ===========================================================

mkdir -p "$ISO_MNT"
mountpoint -q "$ISO_MNT" || mount "$ISO_DEV" "$ISO_MNT"
if [ ! -f "$CSV" ]; then
    echo "$CSV not found - is the exam ISO attached as $ISO_DEV?" >&2
fi

# The importer stays on disk as a separate script: it takes the CSV path
# and can be rerun by hand. Columns: first;last;role;phone;ou;street;zip;city;country;password
cat > "$IMPORT" <<'EOF'
#!/bin/bash

csv_file="$1"

# Create OU
awk -F ';' 'NR>1 {print $5}' "$csv_file" | sort | uniq | while read ou;
do
	samba-tool ou add OU="$ou",DC=au-team,DC=irpo;
done

# Create Users
while IFS=";" read -r firstName lastName role phone ou street zip city country password;
do
	if [ "$firstName" == "First Name" ];
	then
		continue
	fi

	username="${firstName,,}.${lastName,,}"

	samba-tool user add "$username" P@ssw0rd1 \
		--given-name="$firstName" \
		--surname="$lastName" \
		--telephone-number="$phone" \
		--job-title="$role" \
		--userou="OU=$ou"
	samba-tool user setexpiry "$username" --noexpiry
done < "$csv_file"
EOF

chmod +x "$IMPORT"

"$IMPORT" "$CSV"

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

# Number of CSV users that are not in the domain (0 when the import worked)
users_missing() {
    local missing=0 first last
    while IFS=";" read -r first last _; do
        [ "$first" = "First Name" ] && continue
        samba-tool user show "${first,,}.${last,,}" &>/dev/null || missing=$((missing + 1))
    done < <(tr -d '\r' < "$CSV")
    echo "$missing"
}

: > "$LOG"
echo "=== Checking samba-users import ===" | tee -a "$LOG"
check "Users.csv found on the ISO"                  "[ -s \"$CSV\" ]"
check "import_user.sh saved"                        "[ -x \"$IMPORT\" ]"
check "Every user from Users.csv is in the domain"  '[ "$(users_missing)" = "0" ]'
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
# (the imported users stay in the domain)
rm -f "$LOG" "$IMPORT" "$DIR/retry" "$DIR/delete" "$SELF"
DELEOF
chmod +x "$DIR/delete"

rm -f "$SELF"

echo
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} NEXT STEP${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e " Users from Users.csv are in the domain (password P@ssw0rd1)."
echo -e " List them: ${YELLOW}samba-tool user list${NC}"
echo -e " The importer stays as $IMPORT <file.csv>."
echo -e "${CYAN}============================================================${NC}"
echo

exec bash
