#!/bin/bash

set -e

echo "=============================="
echo "  WireGuard + mitmproxy Setup "
echo "=============================="

# -- CONFIGURATION --
WG_INTERFACE="wg0"
MITM_PORT=8888
VPN_SUBNET="10.7.0.0/24"
WG_SERVER_IP="10.7.0.1"
WAN_IFACE=$(ip route get 8.8.8.8 | awk '{ print $5; exit }')

# -- 1. INSTALL WIREGUARD FROM GITHUB SCRIPT --
if [[ ! -f "/etc/wireguard/$WG_INTERFACE.conf" ]]; then
  echo "[+] Downloading and running hwdsl2 WireGuard installer..."
  bash <(curl -sSL https://github.com/hwdsl2/wireguard-install/raw/master/wireguard-install.sh)
else
  echo "[!] WireGuard already appears installed with config at /etc/wireguard/$WG_INTERFACE.conf"
fi

# -- 2. INSTALL DEPENDENCIES --
echo "[+] Installing dependencies..."
apt update && apt install -y iptables iproute2 curl net-tools python3-pip tcpdump

echo "[+] Installing mitmproxy..."
pip3 install mitmproxy

# -- 3. ENABLE IP FORWARDING --
echo "[+] Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# -- 4. IPTABLES RULES --
echo "[+] Applying iptables rules..."
iptables -t nat -F
iptables -F

# Allow SSH on port 22
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# NAT for outbound VPN traffic
iptables -t nat -A POSTROUTING -s $VPN_SUBNET -o $WAN_IFACE -j MASQUERADE

# Redirect HTTP/HTTPS from VPN clients to mitmproxy
iptables -t nat -A PREROUTING -i $WG_INTERFACE -p tcp --dport 80 -j REDIRECT --to-port $MITM_PORT
iptables -t nat -A PREROUTING -i $WG_INTERFACE -p tcp --dport 443 -j REDIRECT --to-port $MITM_PORT

# Allow forwarding
iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT
iptables -A FORWARD -o $WG_INTERFACE -j ACCEPT

# Save rules
echo "[+] Installing iptables-persistent to make rules permanent..."
DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent
netfilter-persistent save

# -- 5. START MITMPROXY --
echo "[+] Starting mitmproxy in transparent mode..."
pkill mitmproxy || true
nohup mitmproxy --mode transparent --listen-port $MITM_PORT --showhost > /var/log/mitmproxy.log 2>&1 &

# -- 6. VERIFY SYSTEM STATE --
echo "[✓] SYSTEM CONFIGURATION CHECKS:"
echo "[*] IP Forwarding:"
sysctl net.ipv4.ip_forward

echo "[*] WireGuard Interface:"
ip a show $WG_INTERFACE || echo "⚠️ Interface $WG_INTERFACE not found. Please complete WireGuard setup."

echo "[*] WireGuard Status:"
wg show || echo "⚠️ wg show failed — check if WireGuard is running."

echo "[*] iptables NAT Rules:"
iptables -t nat -L -n -v

echo "[*] Listening Ports (Check for mitmproxy on $MITM_PORT):"
ss -tulnp | grep $MITM_PORT || echo "⚠️ mitmproxy not listening yet."

# -- 7. DONE --
echo ""
echo "===================================="
echo " ✅ VPN + MITM Transparent Proxy Set "
echo "===================================="
echo "→ VPN Subnet:     $VPN_SUBNET"
echo "→ MITM Port:      $MITM_PORT"
echo "→ WG Interface:   $WG_INTERFACE"
echo "→ WAN Interface:  $WAN_IFACE"
echo "→ Log:            /var/log/mitmproxy.log"
echo ""
echo "📌 Add VPN clients using: sudo bash wireguard-install.sh (to add peers)"
