#!/bin/bash
# userdata-el.sh -- instance user data for RHEL-family AMIs (Rocky/Alma/RHEL).
# Reference in weka.conf / weka_vars.yml as USER_DATA_FILE / user_data_file so
# generate-launch-template.sh bakes it into the launch template.
#
#  - Installs and starts the SSM agent (these AMIs do not ship it; without it
#    the nodes are unreachable -- this package has no SSH path by design).
#    The RPM comes from the regional S3 bucket, so an S3 gateway endpoint is
#    sufficient; no internet path is needed for this step.
#  - Sets SELinux permissive for first-install validation (RHEL-family ships
#    enforcing). Revisit enforcing after the cluster is validated.
#
# Amazon Linux / Ubuntu AMIs need neither step -- do not use this file there.

REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
  http://169.254.169.254/latest/meta-data/placement/region)
REGION="${REGION:-us-east-1}"

if ! systemctl is-enabled --quiet amazon-ssm-agent 2>/dev/null; then
  dnf install -y "https://s3.${REGION}.amazonaws.com/amazon-ssm-${REGION}/latest/linux_amd64/amazon-ssm-agent.rpm" \
    || yum install -y "https://s3.${REGION}.amazonaws.com/amazon-ssm-${REGION}/latest/linux_amd64/amazon-ssm-agent.rpm"
fi
systemctl enable --now amazon-ssm-agent

setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
