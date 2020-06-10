#!/bin/bash

AWS_SUBNET="172.31.0.0/16"

apt install software-properties-common -y
add-apt-repository ppa:wireguard/wireguard -y
apt update
apt install wireguard-dkms wireguard-tools qrencode -y


NET_FORWARD="net.ipv4.ip_forward=1"
sysctl -w  ${NET_FORWARD}
sed -i "s:#${NET_FORWARD}:${NET_FORWARD}:" /etc/sysctl.conf

cd /etc/wireguard

umask 077

SERVER_PRIVKEY=$( wg genkey )
SERVER_PUBKEY=$( echo $SERVER_PRIVKEY | wg pubkey )

echo $SERVER_PUBKEY > ./server_public.key
echo $SERVER_PRIVKEY > ./server_private.key

read -p "Enter the endpoint (external ip and port) in format [ipv4/DNS:port] (e.g. vpn.domain.com:54321):" ENDPOINT
if [ -z $ENDPOINT ]
then
echo "[#]Empty endpoint. Exit"
exit 1;
fi
echo $ENDPOINT > ./endpoint.var

if [ -z "$1" ]
  then 
    read -p "Enter the server address in the VPN subnet (CIDR format), [ENTER] set to default: 10.0.0.1: " SERVER_IP
    if [ -z $SERVER_IP ]
      then SERVER_IP="10.0.0.1"
    fi
  else SERVER_IP=$1
fi

echo $SERVER_IP | grep -o -E '([0-9]+\.){3}' > ./vpn_subnet.var
read VPN_SUBNET < ./vpn_subnet.var

read -p "Enter the ip address of the server DNS (CIDR format), [ENTER] set to default: 1.1.1.1): " DNS
if [ -z $DNS ]
then DNS="1.1.1.1"
fi
echo $DNS > ./dns.var

echo 1 > ./last_used_ip.var

default_eni=$(ip route | awk '/default/{match($0,"dev ([^ ]+)",M); print M[1]; exit}')
read -p "Enter the name of the WAN network interface ([ENTER] set to default: $default_eni): " WAN_INTERFACE_NAME
# read -p "Enter the name of the WAN network interface ([ENTER] set to default: ens5): " WAN_INTERFACE_NAME
if [ -z $WAN_INTERFACE_NAME ]
then
  WAN_INTERFACE_NAME="$default_eni"
fi

PRIVATE_IP=$(ip route | awk '/default/{match($0," ([^ ]+) dev",M); print M[1]; exit}')
AWS_SUBNET="$(echo $PRIVATE_IP | grep -o -E '([0-9]+\.){2}')0.0/16"
ALLOWED_IP="${VPN_SUBNET}0/16, $AWS_SUBNET"

echo $ALLOWED_IP > ./allowed_ip.var
echo $WAN_INTERFACE_NAME > ./wan_interface_name.var

cat ./endpoint.var | sed -e "s/:/ /" | while read SERVER_EXTERNAL_IP SERVER_EXTERNAL_PORT
do
cat > ./wg0.conf.def << EOF
[Interface]
Address = $SERVER_IP
SaveConfig = false
PrivateKey = $SERVER_PRIVKEY
ListenPort = $SERVER_EXTERNAL_PORT
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $WAN_INTERFACE_NAME -j MASQUERADE;
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $WAN_INTERFACE_NAME -j MASQUERADE;
EOF
done

cp -f ./wg0.conf.def ./wg0.conf

systemctl enable wg-quick@wg0
