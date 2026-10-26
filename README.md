# UDEMO

Скачивание скрипта на машине:

```
wget raw.githubusercontent.com/TOST2Q7/UDEMO/refs/heads/main/<скрипт>
bash <скрипт>
```

## Порядок запуска

Перед скриптом на машине без сети вручную настроить интерфейс (адрес, шлюз, resolv.conf). Что вписать, показывает гайд «Next steps» в конце предыдущего скрипта. resolv.conf везде сразу такой:

```
nameserver 77.88.8.8
nameserver 192.168.100.2
search au-team.irpo
```

| # | Машина | Скрипт |
|---|--------|--------|
| 1 | ISP | `isp.sh` → гайды для HQ-RTR и BR-RTR |
| 2 | HQ-RTR | `HQ-RTR.sh` → гайд для HQ-SRV |
| 3 | BR-RTR | `BR-RTR.sh` → гайд для BR-FW |
| 4 | BR-FW | `BR-FW.sh` (межсетевой экран, net_admin на 2027) → гайд для BR-SRV |
| 5 | HQ-SRV | `HQ-SRV.sh` |
| 6 | HQ-CLI | `HQ-CLI.sh` |
| 7 | BR-SRV | `BR-SRV.sh` (Ansible в конце: HQ-RTR, BR-RTR, HQ-SRV, HQ-CLI уже готовы) |

## Задания модулей 2–3

| Машина | Скрипт | Что делает |
|--------|--------|------------|
| BR-SRV | `samba.sh` | Samba DC, группа hq, hquser1-5, chrony |
| BR-SRV | `samba-users.sh` | импорт пользователей из Users.csv с диска |
| BR-SRV | `docker.sh` | docker compose: site + mariadb с диска |
| HQ-SRV | `web.sh` | LAMP, сайт и база webdb с диска |
| ISP | `proxy.sh` | nginx reverse proxy web/docker.au-team.irpo, basic auth |
| HQ-SRV | `gost.sh` | CA и сертификаты ГОСТ, scp на ISP |
| ISP | `nginx-ssl.sh` | сертификаты в /etc/nginx/ssl + гайд по HTTPS |
| HQ-SRV | `fail2ban.sh` | fail2ban для SSH на 2027 |
| HQ-SRV | `cups.sh` | CUPS + cups-pdf |
| по заданию | `atop.sh` | мониторинг atop |

Ansible: `inventory2.yml` и `get_hostname.yml` скачивает `BR-SRV.sh`, отчёты в `/etc/ansible/PC_INFO`.
