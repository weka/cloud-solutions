#!/bin/bash

cat >/usr/sbin/weka_mount.sh <<EOT
while true;do
  backend_ip='<place holder>'

  TOKEN=\$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  INSTANCE_TYPE=\$(curl -H "X-aws-ec2-metadata-token: \$TOKEN" -v http://169.254.169.254/latest/meta-data/instance-type)

  # add additional interfaces and cores based on the instance type
  if [[ "\$INSTANCE_TYPE" == "p5.48xlarge" ]]; then
    declare -a NICS=($1)
    declare -a CORES=($2)
  fi

  echo "\$(date -u): before weka agent installation"

  INSTALLATION_PATH="/tmp/weka"
  mkdir -p \$INSTALLATION_PATH
  cd \$INSTALLATION_PATH

  curl --fail -o install_script.sh "\$backend_ip":14000/dist/v1/install
  chmod +x install_script.sh && ./install_script.sh

  echo "\$(date -u): weka agent installation completed"
  chmod -R 755 /opt/weka/data/agent/tmpfss/cgroup
  sudo sed -i 's/isolate_cpusets=true/isolate_cpusets=false/g' /etc/wekaio/service.conf && systemctl restart weka-agent

  FILESYSTEM_NAME=default # replace with a different filesystem at need
  MOUNT_POINT="/mnt/weka" # replace with a different mount point at need
  mkdir -p "\$MOUNT_POINT"

  mgmt_nic=\$(ls /sys/class/net | grep -vE 'docker|veth|lo' | sort --version-sort | head -n 1)
  mgmt_ip=\$(ip addr show "\$mgmt_nic" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

  for nic in "\${NICS[@]}"
  do
    echo "Moving \$nic to the default namespace"
    ip netns exec sagemaker_agent_namespace ip link set "\$nic" netns default
    weka_net="\$weka_net -o net=\$nic"
  done

  for core in "\${CORES[@]}"
  do
    weka_cores="\$weka_cores -o core=\$core"
  done

  if [ \${#CORES[@]} -eq 0 ]; then
    echo "Unsupported DPDK client instance type: \$INSTANCE_TYPE, mounting in UDP mode"
    weka_net=" -o net=udp"
  fi

   mount -t wekafs -o mgmt_ip=\$mgmt_ip\$weka_net\$weka_cores \$backend_ip/\$FILESYSTEM_NAME \$MOUNT_POINT && echo "wekafs mount completed" && rm -rf \$INSTALLATION_PATH && break
   echo "Retrying weka mount on \$backend_ip in 10 seconds..."
   sleep 10
done
EOT

chmod +x /usr/sbin/weka_mount.sh

cat >/etc/systemd/system/weka_mount.service <<EOL
[Unit]
Description=weka mount unit file.

[Service]
ExecStart=/bin/bash /usr/sbin/weka_mount.sh

[Install]
WantedBy=multi-user.target
EOL
systemctl daemon-reload
systemctl enable weka_mount.service
systemctl start weka_mount.service
