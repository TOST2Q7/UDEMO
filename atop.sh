#!/bin/bash
# Запускать на машине из задания: мониторинг atop (снимок раз в 7 минут, хранение 28 дней)
apt-get install atop -y
cat <<EOF > /etc/default/atop
LOGOPTS="-R"
LOGINTERVAL=420
LOGGENERATIONS=28
LOGPATH=/var/log/atop
EOF
systemctl enable --now atop
systemctl restart atop
