#!/usr/bin/env bash
#
# attach-data-enis.sh -- CROSS-VPC deployments only.
#
# Executes data-eni-plan.json (written by generate-launch-template.sh when
# the data subnet lives in a DIFFERENT VPC than the launch/mgmt subnet):
# creates the data-plane ENIs in the data VPC and attaches them to every
# running cluster instance at the planned card/device indexes, using
# multi-VPC ENI attachments (same account + AZ; EC2 attaches ENA to running
# instances). Idempotent: occupied slots are skipped, so it is safe to
# re-run and is invoked automatically by deploy.sh and site.yml for install
# and scale-out/replace when the plan file exists.
#
# Single-subnet deployments never use this script (no plan file exists).
#
set -euo pipefail

AWS_REGION="us-east-1"        # CHANGEME (or via weka.conf)
CLUSTER_NAME="weka-cluster1"  # CHANGEME (or via weka.conf)
PLAN_FILE="./data-eni-plan.json"

###############################################################################
for _c in ./weka.conf /tmp/weka.conf; do [ -f "$_c" ] && . "$_c" || true; done

die() { echo "FATAL: $*" >&2; exit 1; }
command -v aws >/dev/null 2>&1     || die "aws CLI is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[ -f "$PLAN_FILE" ] || die "$PLAN_FILE not found -- cross-VPC plans are written by generate-launch-template.sh"

read -r DATA_SUBNET DATA_SGS < <(python3 -c "
import json; p = json.load(open('$PLAN_FILE'))
print(p['subnet_id'], ','.join(p['groups']))")
SLOTS=$(python3 -c "
import json; p = json.load(open('$PLAN_FILE'))
print(' '.join(f\"{s['NetworkCardIndex']}:{s['DeviceIndex']}\" for s in p['slots']))")
echo "== plan: $(echo $SLOTS | wc -w | xargs) data ENI(s)/node from ${DATA_SUBNET} =="

IDS=$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:weka-cluster,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
[ -n "$IDS" ] || die "no running instances tagged weka-cluster=${CLUSTER_NAME}"

for IID in $IDS; do
  # occupied (card:dev) slots on this instance
  OCCUPIED=$(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
    --filters "Name=attachment.instance-id,Values=${IID}" \
    --query 'NetworkInterfaces[].Attachment.[NetworkCardIndex,DeviceIndex]' --output text \
    | awk '{c=$1; if (c=="None") c=0; print c":"$2}')
  ATTACHED=0
  for SLOT in $SLOTS; do
    echo "$OCCUPIED" | grep -qx "$SLOT" && continue
    CARD="${SLOT%%:*}"; DEV="${SLOT##*:}"
    ENI=$(aws ec2 create-network-interface --region "$AWS_REGION" \
      --subnet-id "$DATA_SUBNET" --groups $(echo $DATA_SGS | tr ',' ' ') \
      --description "weka-data (nci${CARD}/dev${DEV}) - cross-VPC ENA data plane" \
      --tag-specifications "ResourceType=network-interface,Tags=[{Key=weka-cluster,Value=${CLUSTER_NAME}},{Key=aws-apn-id,Value=pc:epkj0ftddjwa38m3oq9umjjlm}]" \
      --query 'NetworkInterface.NetworkInterfaceId' --output text)
    if ATT=$(aws ec2 attach-network-interface --region "$AWS_REGION" \
      --network-interface-id "$ENI" --instance-id "$IID" \
      --device-index "$DEV" --network-card-index "$CARD" \
      --query 'AttachmentId' --output text 2>&1); then
      aws ec2 modify-network-interface-attribute --region "$AWS_REGION" \
        --network-interface-id "$ENI" \
        --attachment "AttachmentId=${ATT},DeleteOnTermination=true"
      ATTACHED=$((ATTACHED+1))
    else
      aws ec2 delete-network-interface --region "$AWS_REGION" --network-interface-id "$ENI" || true
      die "attach failed on ${IID} card ${CARD} dev ${DEV}: ${ATT}"
    fi
  done
  echo "   ${IID}: attached ${ATTACHED} (already had $(( $(echo $SLOTS | wc -w) - ATTACHED )))"
done
echo "== cross-VPC data ENIs in place =="
