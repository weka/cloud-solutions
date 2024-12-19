#!/bin/bash

cat >/usr/sbin/update_slurm_conf.sh <<EOT
#!/bin/bash

cd /opt/weka_slurm_conf_update
while true;do
  nodesCount=\$(scontrol show node | grep -c "NodeName=")
  specListsCount=\$(scontrol show node | grep -c "CPUSpecList=")
  echo "Nodes count: \$nodesCount, CPUSpecList count: \$specListsCount"
  if [ \$nodesCount -ne \$specListsCount ]; then
    echo "Nodes count and CPUSpecList count mismatch. Updating slurm conf."
    python3 weka_slurm.py $1 || echo "Failed to update slurm conf."
  fi
  sleep 10
done

EOT

chmod +x /usr/sbin/update_slurm_conf.sh

cat >/etc/systemd/system/update_slurm_conf.service <<EOL
[Unit]
Description=update slurm conf unit file.

[Service]
ExecStart=/bin/bash /usr/sbin/update_slurm_conf.sh

[Install]
WantedBy=multi-user.target
EOL
systemctl daemon-reload
systemctl enable update_slurm_conf.service
systemctl start update_slurm_conf.service