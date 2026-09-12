#!/bin/bash

sed -i 's/^dhcp-option=6,77\.88\.8\.8$/dhcp-option=6,192.168.100.2/' /etc/dnsmasq.conf

echo "Change 77.88.8.8 to 192.168.100.2"