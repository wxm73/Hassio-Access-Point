#!/usr/bin/with-contenv bashio

# SIGTERM-handler this funciton will be executed when the container receives the SIGTERM signal (when stopping)
term_handler(){
	logger "Stopping Hass.io Access Point" 0
	ifdown $INTERFACE
	ip link set $INTERFACE down
	ip addr flush dev $INTERFACE
	exit 0
}

# Logging function to set verbosity of output to addon log
logger(){
    msg=$1
    level=$2
    if [ $DEBUG -ge $level ]; then
        echo $msg
    fi
}

CONFIG_PATH=/data/options.json

# Convert integer configs to boolean, to avoid a breaking old configs
declare -r bool_configs=( client_internet_access dhcp )
for i in $bool_configs ; do
    if bashio::config.true $i || bashio::config.false $i ; then
        continue
    elif [ $config_value -eq 0 ] ; then
        bashio::addon.option $config_value false
    else
        bashio::addon.option $config_value true
    fi
done

ADDRESS=$(bashio::config "address")
NETMASK=$(bashio::config "netmask")
INTERFACE=$(bashio::config "interface")
DHCP=$(bashio::config.false "dhcp"; echo $?)
DHCP_START_ADDR=$(bashio::config "dhcp_start_addr" )
DHCP_END_ADDR=$(bashio::config "dhcp_end_addr" )
DNSMASQ_CONFIG_OVERRIDE=$(bashio::config 'dnsmasq_config_override' )
ALLOW_MAC_ADDRESSES=$(bashio::config 'allow_mac_addresses' )
DENY_MAC_ADDRESSES=$(bashio::config 'deny_mac_addresses' )
DEBUG=$(bashio::config 'debug' )
CLIENT_INTERNET_ACCESS=$(bashio::config.false 'client_internet_access'; echo $?)
CLIENT_DNS_OVERRIDE=$(bashio::config 'client_dns_override' )
DNSMASQ_CONFIG_OVERRIDE=$(bashio::config 'dnsmasq_config_override' )

# Get the Default Route interface
DEFAULT_ROUTE_INTERFACE=$(ip route show default | awk '/^default/ { print $5 }')

echo "Starting Hass.io Access Point Addon"

# Setup interface
logger "# Setup interface:" 1
logger "Add to /etc/network/interfaces: iface $INTERFACE inet static" 1
# Create and add our interface to interfaces file
echo "iface $INTERFACE inet static"$'\n' >> /etc/network/interfaces

logger "Run command: nmcli dev set $INTERFACE managed no" 1
nmcli dev set $INTERFACE managed no

logger "Run command: ip link set $INTERFACE down" 1
ip link set $INTERFACE down

logger "Add to /etc/network/interfaces: address $ADDRESS" 1
echo "address $ADDRESS"$'\n' >> /etc/network/interfaces
logger "Add to /etc/network/interfaces: netmask $NETMASK" 1
echo "netmask $NETMASK"$'\n' >> /etc/network/interfaces

logger "Run command: ip link set $INTERFACE up" 1
ip link set $INTERFACE up

# Setup signal handlers
trap 'term_handler' SIGTERM

# Enforces required env variables
required_vars=(address netmask)
for required_var in "${required_vars[@]}"; do
    bashio::config.require $required_var "An AP cannot be created without this information"
done


# Set address for the selected interface. Not sure why this is now not being set via /etc/network/interfaces, but maybe interfaces file is no longer required...
ifconfig $INTERFACE $ADDRESS netmask $NETMASK

# Setup dnsmasq.conf if DHCP is enabled in config
if $(bashio::config.true "dhcp"); then
    logger "# DHCP enabled. Setup dnsmasq:" 1
    logger "Add to dnsmasq.conf: dhcp-range=$DHCP_START_ADDR,$DHCP_END_ADDR,12h" 1
        echo "dhcp-range=$DHCP_START_ADDR,$DHCP_END_ADDR,12h"$'\n' >> /dnsmasq.conf
        logger "Add to dnsmasq.conf: interface=$INTERFACE" 1
        echo "interface=$INTERFACE"$'\n' >> /dnsmasq.conf

    ## DNS
    dns_array=()
        if [ ${#CLIENT_DNS_OVERRIDE} -ge 1 ]; then
            dns_string="dhcp-option=6"
            DNS_OVERRIDES=($CLIENT_DNS_OVERRIDE)
            for override in "${DNS_OVERRIDES[@]}"; do
                dns_string+=",$override"
            done
            echo "$dns_string"$'\n' >> /dnsmasq.conf
            logger "Add custom DNS: $dns_string" 0
        else
            IFS=$'\n' read -r -d '' -a dns_array < <( nmcli device show | grep IP4.DNS | awk '{print $2}' && printf '\0' )

            if [ ${#dns_array[@]} -eq 0 ]; then
                logger "Couldn't get DNS servers from host. Consider setting with 'client_dns_override' config option." 0
            else
                dns_string="dhcp-option=6"
                for dns_entry in "${dns_array[@]}"; do
                    dns_string+=",$dns_entry"
                done
                echo "$dns_string"$'\n' >> /dnsmasq.conf
                logger "Add DNS: $dns_string" 0
            fi

        fi

    # Append override options to dnsmasq.conf
    if [ ${#DNSMASQ_CONFIG_OVERRIDE} -ge 1 ]; then
        logger "# Custom dnsmasq config options:" 0
        DNSMASQ_OVERRIDES=($DNSMASQ_CONFIG_OVERRIDE)
        for override in "${DNSMASQ_OVERRIDES[@]}"; do
            echo "$override"$'\n' >> /dnsmasq.conf
            logger "Add to dnsmasq.conf: $override" 0
        done
    fi
else
	logger "# DHCP not enabled. Skipping dnsmasq" 1
fi

# Setup Client Internet Access
if $(bashio::config.true "client_internet_access"); then

    ## Route traffic
    iptables-nft -t nat -A POSTROUTING -o $DEFAULT_ROUTE_INTERFACE -j MASQUERADE
    iptables-nft -P FORWARD ACCEPT
    iptables-nft -F FORWARD
fi

# Start dnsmasq if DHCP is enabled in config
if $(bashio::config.true "dhcp"); then
    logger "## Starting dnsmasq daemon" 1
    dnsmasq -C /dnsmasq.conf
fi

