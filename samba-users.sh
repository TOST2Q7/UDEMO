#!/bin/bash
# Запускать на BR-SRV после samba.sh: импорт пользователей из Users.csv с диска задания
mount /dev/sr0 /mnt

cat > import_user.sh <<'EOF'
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

chmod +x import_user.sh

./import_user.sh /mnt/Users.csv
