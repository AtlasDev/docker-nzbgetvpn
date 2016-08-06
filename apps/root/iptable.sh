#!/bin/bash

# check for presence of network interface docker0
check_network=$(ifconfig | grep docker0)

# if network interface docker0 is present then we are running in host mode and thus must exit
if [[ ! -z "${check_network}" ]]; then
	echo "[crit] Network type detected as 'Host', this will cause major issues, please stop the container and switch back to 'Bridge' mode" && exit 1
fi

# ip route
###

if [[ ! -z "${LAN_NETWORK}" ]]; then

	# split comma seperated string into list from LAN_NETWORK env variable
	IFS=',' read -ra lan_network_list <<< "${LAN_NETWORK}"

	# process lan networks in the list
	for lan_network_item in "${lan_network_list[@]}"; do

		# strip whitespace from start and end of lan_network_item
		lan_network_item=$(echo "${lan_network_item}" | sed -e 's/^[ \t]*//')

		echo "[info] Adding ${lan_network_item} as route via docker eth0"
		ip route add "${lan_network_item}" via "${DEFAULT_GATEWAY}" dev eth0

	done

else

	echo "[crit] LAN network not defined, please specify via env variable LAN_NETWORK" && exit 1

fi

echo "[info] ip route defined as follows..."
echo "--------------------"
ip route
echo "--------------------"


# setup iptables marks to allow routing of defined ports via eth0
###

# check kernel for iptable_mangle module
lsmod | grep "iptable_mangle" > /dev/null
iptable_mangle_exit_code=$?

if [[ "${DEBUG}" == "true" ]]; then
	echo "[debug] Modules currently loaded for kernel" ; lsmod
fi

# if iptable_mangle is not available then attempt to load module
if [[ $iptable_mangle_exit_code != 0 ]]; then

	# attempt to load module
	echo "[info] iptable_mangle module not supported, attempting to load..."
	modprobe iptable_mangle > /dev/null
	iptable_mangle_exit_code=$?
fi

# if iptable_mangle is available then set fwmark
if [[ $iptable_mangle_exit_code == 0 ]]; then

	echo "[info] iptable_mangle support detected, adding fwmark for tables"

	# setup route for nzbget webui using set-mark to route traffic for port 6789 to eth0
	echo "6789    webui" >> /etc/iproute2/rt_tables
	ip rule add fwmark 1 table webui
	ip route add default via $DEFAULT_GATEWAY table webui

else

	echo "[warn] iptable_mangle module not supported, you will not be able to connect to nzbget webui outside of your LAN"

fi

# input iptable rules
###

# set policy to drop for input
iptables -P INPUT DROP

# accept input to tunnel adapter
iptables -A INPUT -i tun0 -j ACCEPT

# accept input to/from docker containers (172.x range is internal dhcp)
iptables -A INPUT -s 172.17.0.0/16 -d 172.17.0.0/16 -j ACCEPT

# accept input to vpn gateway
iptables -A INPUT -i eth0 -p $VPN_PROTOCOL --sport $VPN_PORT -j ACCEPT

# accept input to nzbget webui port 6789
iptables -A INPUT -i eth0 -p tcp --dport 6789 -j ACCEPT
iptables -A INPUT -i eth0 -p tcp --sport 6789 -j ACCEPT

# process lan networks in the list
for lan_network_item in "${lan_network_list[@]}"; do

	# strip whitespace from start and end of lan_network_item
	lan_network_item=$(echo "${lan_network_item}" | sed -e 's/^[ \t]*//')

	# accept input to nzbget daemon port - used for lan access
	iptables -A INPUT -i eth0 -s "${lan_network_item}" -p tcp --dport 58846 -j ACCEPT

done

# accept input dns lookup
iptables -A INPUT -p udp --sport 53 -j ACCEPT

# accept input icmp (ping)
iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT

# accept input to local loopback
iptables -A INPUT -i lo -j ACCEPT

# output iptable rules
###

# set policy to drop for output
iptables -P OUTPUT DROP

# accept output from tunnel adapter
iptables -A OUTPUT -o tun0 -j ACCEPT

# accept output to/from docker containers (172.x range is internal dhcp)
iptables -A OUTPUT -s 172.17.0.0/16 -d 172.17.0.0/16 -j ACCEPT

# accept output from vpn gateway
iptables -A OUTPUT -o eth0 -p $VPN_PROTOCOL --dport $VPN_PORT -j ACCEPT

# if iptable mangle is available (kernel module) then use mark
if [[ $iptable_mangle_exit_code == 0 ]]; then

	# accept output from nzbget webui port 6789 - used for external access
	iptables -t mangle -A OUTPUT -p tcp --dport 6789 -j MARK --set-mark 1
	iptables -t mangle -A OUTPUT -p tcp --sport 6789 -j MARK --set-mark 1

fi

# accept output from nzbget webui port 6789 - used for lan access
iptables -A OUTPUT -o eth0 -p tcp --dport 6789 -j ACCEPT
iptables -A OUTPUT -o eth0 -p tcp --sport 6789 -j ACCEPT

# process lan networks in the list
for lan_network_item in "${lan_network_list[@]}"; do

	# strip whitespace from start and end of lan_network_item
	lan_network_item=$(echo "${lan_network_item}" | sed -e 's/^[ \t]*//')

	# accept output to nzbget daemon port - used for lan access
	iptables -A OUTPUT -o eth0 -d "${lan_network_item}" -p tcp --sport 58846 -j ACCEPT

done

# accept output for dns lookup
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT

# accept output for icmp (ping)
iptables -A OUTPUT -p icmp --icmp-type echo-request -j ACCEPT

# accept output from local loopback adapter
iptables -A OUTPUT -o lo -j ACCEPT

echo "[info] iptables defined as follows..."
echo "--------------------"
iptables -S
echo "--------------------"
