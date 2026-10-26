#!/bin/bash
# Запускать на HQ-SRV: принт-сервер CUPS с виртуальным PDF-принтером
apt-get install -y cups cups-pdf
systemctl enable --now cups
cupsctl --share-printers --remote-any
systemctl restart cups
