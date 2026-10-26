#!/bin/bash
# Запускать на ISP: nginx reverse proxy web.au-team.irpo -> HQ-RTR:8080, docker.au-team.irpo -> BR-RTR:8080
apt-get update
apt-get install -y nginx apache2-htpasswd

# Basic auth для web.au-team.irpo
htpasswd -bc /etc/nginx/.htpasswd WEB 'P@ssw0rd'

mkdir -p /etc/nginx/sites-available.d
mkdir -p /etc/nginx/sites-enabled.d
mkdir -p /etc/nginx/ssl
cat << 'EOF' > /etc/nginx/sites-available.d/default.conf
server {
    #listen 443 ssl;
    listen 80;
    server_name web.au-team.irpo;

    #ssl_certificate /etc/nginx/ssl/web.au-team.irpo.cer;
    #ssl_certificate_key /etc/nginx/ssl/web.au-team.irpo.key;
    #ssl_ciphers GOST2012-GOST8912-GOST8912:HIGH:MEDIUM;
    #ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
    #ssl_prefer_server_ciphers on;

    location / {
        proxy_pass http://172.16.1.2:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        auth_basic "Restricted area";
        auth_basic_user_file /etc/nginx/.htpasswd;
    }
}

server {
    listen 80;
    #listen 443 ssl;
    server_name docker.au-team.irpo;

    #ssl_certificate /etc/nginx/ssl/docker.au-team.irpo.cer;
    #ssl_certificate_key /etc/nginx/ssl/docker.au-team.irpo.key;
    #ssl_ciphers GOST2012-GOST8912-GOST8912:HIGH:MEDIUM;
    #ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
    #ssl_prefer_server_ciphers on;

    location / {
        proxy_pass http://172.16.2.2:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
ln -sf /etc/nginx/sites-available.d/default.conf /etc/nginx/sites-enabled.d/
nginx -t
systemctl enable --now nginx
systemctl restart nginx
apt-get install -y openssl-gost-engine
control openssl-gost enabled
