#!/usr/bin/env bash
#
# deploy.sh -- run the WEKA installer or day-2 operations on your cluster
# nodes FROM YOUR WORKSTATION, over SSM. No SSH, no manual node selection.
#
#   ./deploy.sh install                 run day-0 (install/weka-ssm-install.sh)
#   ./deploy.sh day2 status             day-2 status (install/weka-day2.sh)
#   ./deploy.sh day2 scale-out          adopt new tagged nodes
#   ./deploy.sh day2 scale-in i-xxxx    remove a node
#   ./deploy.sh day2 replace i-xxxx     replace a failed node
#
# What it does: finds your cluster nodes by tag, picks the elected
# orchestrator (lowest instance-id), ships the (already configured) script to
# it inline over SSM (gzip+base64 -- no S3 staging needed), runs it, and
# streams status until it finishes.
#
# EDIT install/weka-ssm-install.sh and install/weka-day2.sh FIRST -- this
# driver ships them as-is. Requires: aws CLI with credentials for the target
# account. Run from the package root.
#
set -euo pipefail

###############################################################################
##                        CUSTOMER CONFIGURATION                             ##
###############################################################################

AWS_REGION="us-east-1"        # CHANGEME: deployment region
CLUSTER_NAME="weka-cluster1"  # CHANGEME: must match the installer + launch template tag

TIMEOUT=3600                  # seconds to allow the remote run
INSTALLER="install/weka-ssm-install.sh"
DAY2="install/weka-day2.sh"

###############################################################################
# weka.conf overlay -- the single source of truth (RUNBOOK §4). Also shipped
# to the target node automatically so the installers read the same values.
[ -f ./weka.conf ] && . ./weka.conf || true

###############################################################################

die() { echo "FATAL: $*" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || die "aws CLI is required"

OP="${1:-}"; shift || true
case "$OP" in
  install) SCRIPT="$INSTALLER"; RARGS="" ;;
  day2)    SCRIPT="$DAY2";      RARGS="$*"
           [ -n "$RARGS" ] || die "usage: $0 day2 {status|scale-out|scale-in <iid>...|replace <iid>}" ;;
  *) die "usage: $0 {install|day2 <subcommand> [args]}" ;;
esac
[ -f "$SCRIPT" ] || die "$SCRIPT not found -- run from the package root"

# sanity: warn if the target script's CLUSTER_NAME differs (moot when
# weka.conf exists -- everything reads it)
if [ ! -f ./weka.conf ]; then
  SC_CLUSTER=$(grep -m1 '^CLUSTER_NAME=' "$SCRIPT" | cut -d'"' -f2)
  [ "$SC_CLUSTER" = "$CLUSTER_NAME" ] \
    || echo "WARN: $SCRIPT has CLUSTER_NAME=\"$SC_CLUSTER\" but deploy.sh has \"$CLUSTER_NAME\" -- keep them in sync"
fi

echo "== discovering nodes tagged weka-cluster=${CLUSTER_NAME} in ${AWS_REGION} =="
# retry until the EXPECTED node count is running (freshly launched instances
# sit in 'pending' first; electing an orchestrator from a partial set would
# disagree with the installer's own lowest-id election)
WANT="${EXPECTED_NODES:-1}"
DEADLINE=$(( $(date +%s) + 300 ))
while :; do
  # portable (macOS bash 3.2 has no mapfile); instance ids contain no spaces
  NODES=($(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:weka-cluster,Values=${CLUSTER_NAME}" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n' | sort))
  [ ${#NODES[@]} -ge "$WANT" ] && break
  [ $(date +%s) -gt $DEADLINE ] && {
    [ ${#NODES[@]} -gt 0 ] && break   # proceed with what exists (day-2 ops on partial fleets)
    die "no running instances found with tag weka-cluster=${CLUSTER_NAME} after 5 min -- check the tag and region"
  }
  echo "   ${#NODES[@]}/${WANT} running -- retrying..."
  sleep 15
done
# WEKA_ORCH: day-2 override -- scale-out candidates are tagged BEFORE they are
# members, and a new node with the lowest instance-id would win the election
# despite having no weka installed. Point day-2 ops at a known MEMBER:
#   WEKA_ORCH=i-0abc123 ./deploy.sh day2 scale-out
# (day-0 install must keep the lowest-id election -- the installer self-checks it)
ORCH="${WEKA_ORCH:-${NODES[0]}}"
echo "   ${#NODES[@]} node(s); orchestrator: ${ORCH}"

echo "== waiting for SSM registration =="
DEADLINE=$(( $(date +%s) + 600 ))
while :; do
  IDS=$(printf '%s,' "${NODES[@]}"); IDS="${IDS%,}"
  ONLINE=$(aws ssm describe-instance-information --region "$AWS_REGION" \
    --filters "Key=InstanceIds,Values=${IDS}" \
    --query 'length(InstanceInformationList[?PingStatus==`Online`])' --output text)
  echo "   ${ONLINE}/${#NODES[@]} online"
  [ "$ONLINE" = "${#NODES[@]}" ] && break
  [ $(date +%s) -gt $DEADLINE ] && die "nodes not SSM-online after 10 min -- check §3 prerequisites"
  sleep 15
done

# cross-VPC deployments: make sure the planned data ENIs are attached before
# any node-side work (no-op when no plan file exists = the normal path)
if [ -f ./data-eni-plan.json ]; then
  case "$OP $RARGS" in
    install*|*scale-out*|*replace*)
      echo "== cross-VPC plan detected: ensuring data ENIs are attached =="
      bash scripts/attach-data-enis.sh ;;
  esac
fi

# ship inline: gzip+base64 (portable across macOS/Linux base64 variants)
B64=$(gzip -c "$SCRIPT" | base64 | tr -d '\n')
CONF_PREFIX=""
if [ -f ./weka.conf ]; then
  CB64=$(gzip -c ./weka.conf | base64 | tr -d '\n')
  CONF_PREFIX="echo ${CB64} | base64 -d | gunzip | sudo tee /tmp/weka.conf >/dev/null && "
fi
REMOTE="${CONF_PREFIX}echo ${B64} | base64 -d | gunzip > /tmp/weka-run.sh && sudo bash /tmp/weka-run.sh ${RARGS} > /tmp/weka-run.log 2>&1; rc=\$?; tail -c 20000 /tmp/weka-run.log; exit \$rc"

echo "== running '${OP} ${RARGS}' on ${ORCH} (log on node: /tmp/weka-run.log) =="
CID=$(aws ssm send-command --region "$AWS_REGION" \
  --document-name AWS-RunShellScript \
  --instance-ids "$ORCH" \
  --comment "weka ${CLUSTER_NAME} ${OP} ${RARGS}" \
  --timeout-seconds "$TIMEOUT" \
  --parameters "commands=[\"${REMOTE}\"],executionTimeout=[\"${TIMEOUT}\"]" \
  --query 'Command.CommandId' --output text)
echo "   command id: ${CID}"

while :; do
  ST=$(aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$CID" --instance-id "$ORCH" --query Status --output text 2>/dev/null || echo Pending)
  echo "   $(date +%H:%M:%S)  ${ST}"
  case "$ST" in Success|Failed|Cancelled|TimedOut) break ;; esac
  sleep 20
done

echo
echo "================ output (tail) ================"
aws ssm get-command-invocation --region "$AWS_REGION" \
  --command-id "$CID" --instance-id "$ORCH" \
  --query 'StandardOutputContent' --output text
if [ "$ST" != "Success" ]; then
  echo "================ stderr (tail) ================"
  aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$CID" --instance-id "$ORCH" \
    --query 'StandardErrorContent' --output text
  die "'${OP}' finished with status ${ST} -- full log on ${ORCH}:/tmp/weka-run.log"
fi
echo "== '${OP} ${RARGS}' completed successfully =="
