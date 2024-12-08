#!/bin/bash
set -ex

# setup CycleCloud variables to find cluster IPs
ccuser=$(jetpack config cyclecloud.config.username)
ccpass=$(jetpack config cyclecloud.config.password)
ccurl=$(jetpack config cyclecloud.config.web_server)
mount_point=$(jetpack config weka.mount_point)
fs=$(jetpack config weka.fs)


# Pick a package manager
yum install -y epel-release || true
apt install -y epel-release || true

if [ -e "/etc/netplan/50-cloud-init.yaml" ]; then
    cat <<-EOF | sed -i "/    ethernets:/r /dev/stdin" /etc/netplan/50-cloud-init.yaml
        eth1:
            dhcp4: true
EOF
    netplan apply
fi

if [ -e "/etc/sysconfig/network-scripts/ifcfg-eth0" ]; then
    cp /etc/sysconfig/network-scripts/ifcfg-eth0 /etc/sysconfig/network-scripts/ifcfg-eth1
    sed -i "s/eth0/eth1/g"  /etc/sysconfig/network-scripts/ifcfg-eth1
    systemctl restart NetworkManager
fi

# Find the mount addresses if deployed by CycleCloud...otherwise use manual entries
if [ "$(jetpack config weka.cycle)" == "True" ]; then
    cluster_name=$(jetpack config weka.cluster_name)
    # Get the list of Weka cluster IPs from CycleCloud
    IPS=$(curl -s -k --user ${ccuser}:${ccpass} "${ccurl}/clusters/${cluster_name}/nodes" \
      | jq -r '.nodes[] |  .PrivateIp' | xargs | sed -e 's/ /,/g')
else
    IPS=$(jetpack config weka.cluster_address)
fi

# Pick a random Weka node from the list of IPs
num_commas=$(echo $IPS | tr -cd , | wc -c )
num_nodes=$(echo "$((num_commas + 1))")
weka_address=$(echo $IPS | cut -d ',' -f $(( ( RANDOM % ${num_nodes} )  + 1 )))


# Create a mount point
mkdir -p ${mount_point}

# Install the WEKA agent on the client machine:
curl http://${weka_address}:14000/dist/v1/install | sh


rm -rf $INSTALLATION_PATH

echo "$(date -u): before weka agent installation"

INSTALLATION_PATH="/tmp/weka"
mkdir -p $INSTALLATION_PATH
cd $INSTALLATION_PATH

gateways="${all_gateways}"
FRONTEND_CONTAINER_CORES_NUM=1
NICS_NUM=2
eth0=$(ifconfig | grep eth0 -C2 | grep 'inet ' | awk '{print $2}')
eth1_ip=$(ifconfig | grep eth1 -C2 | grep 'inet ' | awk '{print $2}')
eth1_mask=$(echo -n /;ip -4 addr | awk '/eth1/ { getline; {print $2} }' | cut -f2 -d/)

#### new additions to establish network interface for weka mount
eth1mac=$(ifconfig eth1|grep ether|awk '{print $2'})
mntdev=$(ifconfig|grep $eth1mac -B2|grep mtu|grep -v eth1|awk '{print $1}'| cut -d':' -f1)



function retry {
  local retry_max=$1
  local retry_sleep=$2
  shift 2
  local count=$retry_max
  while [ $count -gt 0 ]; do
      "$@" && break
      count=$(($count - 1))
      echo "Retrying $* in $retry_sleep seconds..."
      sleep $retry_sleep
  done
  [ $count -eq 0 ] && {
      echo "Retry failed [$retry_max]: $*"
      echo "$(date -u): retry failed"
      return 1
  }
  return 0
}

mount_command="mount -t wekafs ${weka_address}/${fs} -o num_cores=$FRONTEND_CONTAINER_CORES_NUM -o net=${mntdev}/${eth1_ip}${eth1_mask} -o mgmt_ip=$eth0 $mount_point"


retry 60 45 $mount_command

rm -rf $INSTALLATION_PATH

echo "$(date -u): wekafs mount complete"
