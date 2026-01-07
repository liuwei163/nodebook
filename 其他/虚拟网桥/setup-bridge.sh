#!/bin/bash
set -e # 遇到错误即停止
BR_NAME="vmarkbr0"
PHY_IF="eno1.30"
IP_ADDR="192.168.12.200/23"
GATEWAY="192.168.12.254"

echo "[1] Creating bridge and adding interface..."
brctl addbr $BR_NAME
brctl addif $BR_NAME $PHY_IF
ip addr flush dev $PHY_IF # 清空物理网卡IP
ip addr add $IP_ADDR dev $BR_NAME
ip link set $BR_NAME up
ip link set $PHY_IF up

echo "[2] Setting default gateway..."
ip route add default via $GATEWAY dev $BR_NAME

echo "[3] Configuring packet forwarding..."
iptables -t filter -A FORWARD -i $BR_NAME -j ACCEPT
iptables -t filter -A FORWARD -o $BR_NAME -j ACCEPT
sysctl -w net.ipv4.ip_forward=1

echo "Bridge setup complete. Verifying..."
brctl show
ip addr show $BR_NAME