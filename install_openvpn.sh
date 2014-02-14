#!/usr/bin/env bash
#

# Functions
ok() {
    echo -e '\e[32m'$1'\e[m';
}

die() {
    echo -e '\e[1;31m'$1'\e[m'; exit 1;
}

# Sanity check
if [[ $(id -g) != "0" ]] ; then
    die "❯❯❯ Script must be run as root."
fi

if [[  ! -e /dev/net/tun ]] ; then
    die "❯❯❯ TUN/TAP device is not available."
fi

dpkg -l openvpn > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
    die "❯❯❯ OpenVPN is already installed."
fi

# Install openvpn
ok "❯❯❯ apt-get update"
apt-get update -q > /dev/null 2>&1
ok "❯❯❯ apt-get install openvpn curl openssl"
apt-get install -qy openvpn curl > /dev/null 2>&1

# IP Address
SERVER_IP=$(curl ipv4.icanhazip.com)
if [[ -z "${SERVER_IP}" ]]; then
    SERVER_IP=$(ip a | awk -F"[ /]+" '/global/ && !/127.0/ {print $3; exit}')
fi

# Generate CA Config
ok "❯❯❯ Generating CA Config"
openssl dhparam -out /etc/openvpn/dh.pem 2048 > /dev/null 2>&1
openssl genrsa -out /etc/openvpn/ca-key.pem 2048 > /dev/null 2>&1
chmod 600 /etc/openvpn/ca-key.pem
openssl req -new -key /etc/openvpn/ca-key.pem -out /etc/openvpn/ca-csr.pem -subj /CN=OpenVPN-CA/ > /dev/null 2>&1
openssl x509 -req -in /etc/openvpn/ca-csr.pem -out /etc/openvpn/ca.pem -signkey /etc/openvpn/ca-key.pem -days 36525 > /dev/null 2>&1
echo 01 > /etc/openvpn/ca.srl

# Generate Server Config
ok "❯❯❯ Generating Server Config"
openssl genrsa -out /etc/openvpn/server-key.pem 2048 > /dev/null 2>&1
chmod 600 /etc/openvpn/server-key.pem
openssl req -new -key /etc/openvpn/server-key.pem -out /etc/openvpn/server-csr.pem -subj /CN=OpenVPN/ > /dev/null 2>&1
openssl x509 -req -in /etc/openvpn/server-csr.pem -out /etc/openvpn/server-cert.pem -CA /etc/openvpn/ca.pem -CAkey /etc/openvpn/ca-key.pem -days 36525 > /dev/null 2>&1

cat > /etc/openvpn/udp1194.conf <<EOF
server 10.8.0.0 255.255.255.0
verb 3
duplicate-cn
key server-key.pem
ca ca.pem
cert server-cert.pem
dh dh.pem
keepalive 10 120
persist-key
persist-tun
comp-lzo
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"

user nobody
group nogroup

proto udp
port 1194
dev tun1194
status openvpn-status-1194.log
EOF

# Generate Client Config
ok "❯❯❯ Generating Client Config"
openssl genrsa -out /etc/openvpn/client-key.pem 2048 > /dev/null 2>&1
chmod 600 /etc/openvpn/client-key.pem
openssl req -new -key /etc/openvpn/client-key.pem -out /etc/openvpn/client-csr.pem -subj /CN=OpenVPN-Client/ > /dev/null 2>&1
openssl x509 -req -in /etc/openvpn/client-csr.pem -out /etc/openvpn/client-cert.pem -CA /etc/openvpn/ca.pem -CAkey /etc/openvpn/ca-key.pem -days 36525 > /dev/null 2>&1

cat > /etc/openvpn/client.ovpn <<EOF
client
nobind
dev tun
redirect-gateway def1 bypass-dhcp
remote $SERVER_IP 1194 udp
comp-lzo yes

<key>
$(cat /etc/openvpn/client-key.pem)
</key>
<cert>
$(cat /etc/openvpn/client-cert.pem)
</cert>
<ca>
$(cat /etc/openvpn/ca.pem)
</ca>
EOF

# Iptables
if [[ ! -f /proc/user_beancounters ]]; then
    N_INT = $(ip a |awk -v sip="$SERVER_IP" '$0 ~ sip { print $7}')
    iptables -t nat -A POSTROUTING -s 10.1.0.0/24 -o $N_INT -j MASQUERADE
else
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j SNAT --to-source $SERVER_IP
fi

iptables-save > /etc/iptables.conf

cat > /etc/network/if-up.d/iptables <<EOF
#!/bin/sh
iptables-restore
EOF

chmod +x /etc/network/if-up.d/iptables

# Enable net.ipv4.ip_forward
sed -i 's|#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|' /etc/sysctl.conf
echo 1 > /proc/sys/net/ipv4/ip_forward

# Restart Service
ok "❯❯❯ service openvpn restart"
service openvpn restart > /dev/null 2>&1
ok "❯❯❯ Your client config is available at /etc/openvpn/client.ovpn"
ok "❯❯❯ All done!"
