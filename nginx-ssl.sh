#!/bin/bash
# Запускать на ISP после proxy.sh и gost.sh (сертификаты уже скопированы в ~)
mkdir -p /etc/nginx/ssl
mv ~/docker.au-team.irpo.* /etc/nginx/ssl
mv ~/web.au-team.irpo.* /etc/nginx/ssl

apt-get install -y openssl-gost-engine
control openssl-gost enabled

echo -e "\033[1;36m=== Next steps \033[30m\033[106mHTTPS\033[0m \033[1;36m==="
echo -e "> vim /etc/nginx/sites-available.d/default.conf"
echo -e "раскомментировать listen 443 ssl; и строки ssl_*, закомментировать listen 80;"
echo -e "> nginx -t && systemctl restart nginx"
echo -e "\033[1;36m=========================================\033[0m"
