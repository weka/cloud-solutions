#!/usr/bin/env bash
#
# weka-env-preflight.sh -- ENVIRONMENT conformance check, run from your
# WORKSTATION before anything launches (the environment-side counterpart of
# scripts/weka-preflight.sh, which checks each node).
#
# Verifies the runbook §3 prerequisites against the live account: subnet and
# VPC settings, egress path (NAT vs the IGW-without-public-IPs trap), S3 and
# SSM reachability for the nodes, security group self-references, instance
# profile, AMI, instance-type availability in the AZ, and the capacity
# reservation. Read-only: makes no changes.
#
#   ./scripts/weka-env-preflight.sh          # values come from ./weka.conf
#
# Exit code: 0 = no FAILs (warnings possible), 1 = at least one FAIL.
#
set -uo pipefail

###############################################################################
##                        CUSTOMER CONFIGURATION                             ##
###############################################################################
AWS_REGION="us-east-1"        # CHANGEME (or via weka.conf)
CLUSTER_NAME="weka-cluster1"  # CHANGEME (or via weka.conf)
INSTANCE_TYPE=""              # CHANGEME (or via weka.conf)
AMI_ID=""                     # CHANGEME (or via weka.conf)
SUBNET_ID=""                  # CHANGEME (or via weka.conf)
SG_ENA=""                     # CHANGEME (or via weka.conf)
SG_EFA=""                     # optional
SG_MGMT=""                    # optional (split-subnet layouts)
MGMT_SUBNET_ID=""             # optional (split-subnet layouts)
INSTANCE_PROFILE_ARN=""       # CHANGEME (or via weka.conf)
EXPECTED_NODES=1
DRIVE_CORES=0; COMPUTE_CORES=0; FRONTEND_CORES=0
WEKA_INSTALL_S3=""            # optional: s3://bucket/key
CAPACITY_RESERVATION_ID=""    # optional: cr-...
###############################################################################
for _c in ./weka.conf /tmp/weka.conf; do [ -f "$_c" ] && . "$_c" || true; done

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN+1)); }
bad()  { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
fix()  { echo "       fix: $*"; }   # copy-paste remediation for the line above
AWS() { aws --region "$AWS_REGION" "$@"; }

command -v aws >/dev/null 2>&1 || { echo "FATAL: aws CLI is required"; exit 1; }

echo "##### WEKA environment preflight: cluster=${CLUSTER_NAME} region=${AWS_REGION} #####"

# ---------- 1. credentials ----------
IDENT=$(AWS sts get-caller-identity --query '[Account,Arn]' --output text 2>/dev/null)
if [ -n "$IDENT" ]; then ok "credentials valid: $(echo $IDENT | awk '{print $2}') (account $(echo $IDENT | awk '{print $1}'))"
else bad "no working AWS credentials for region ${AWS_REGION}"; echo "##### RESULT: cannot continue #####"; exit 1; fi

# ---------- 1b. operator permissions (best-effort simulation) ----------
# Simulates the key MUTATING actions the deploy needs (reads are implicitly
# verified by this script's own calls). Needs iam:SimulatePrincipalPolicy;
# gracefully degrades to a WARN when the caller cannot simulate. NB the
# simulator does not model SCPs/permission boundaries -- a PASS here can
# still be vetoed by org-level controls.
CALLER_ARN=$(echo "$IDENT" | awk '{print $2}')
case "$CALLER_ARN" in
  *:assumed-role/*) RN=$(echo "$CALLER_ARN" | awk -F/ '{print $(NF-1)}')
                    ACCT=$(echo "$IDENT" | awk '{print $1}')
                    SIM_ARN="arn:aws:iam::${ACCT}:role/${RN}" ;;
  *)                SIM_ARN="$CALLER_ARN" ;;
esac
SIM_ACTIONS="ec2:RunInstances ec2:CreateLaunchTemplate ec2:CreateSecurityGroup ec2:CreateNetworkInterface ec2:TerminateInstances iam:CreateRole iam:PassRole ssm:SendCommand ssm:StartSession secretsmanager:GetSecretValue ssm:GetParameter"
SIM_OUT=$(aws iam simulate-principal-policy --policy-source-arn "$SIM_ARN" \
  --action-names $SIM_ACTIONS \
  --query 'EvaluationResults[?EvalDecision!=`allowed`].EvalActionName' --output text 2>&1)
if echo "$SIM_OUT" | grep -qiE 'AccessDenied|NoSuchEntity|ValidationError|error'; then
  warn "cannot simulate operator permissions (${SIM_ARN} lacks iam:SimulatePrincipalPolicy or is not simulatable) -- ensure iam/operator-policy.json is attached to whoever runs the deploy"
elif [ -n "$SIM_OUT" ] && [ "$SIM_OUT" != "None" ]; then
  bad "operator is missing permission(s): $(echo $SIM_OUT | tr '\t' ' ') -- the deploy will fail partway"
  fix "attach iam/operator-policy.json (pre-filled in this package) to ${SIM_ARN}"
else
  ok "operator permissions: all key deploy actions allowed (simulated; SCPs not modeled)"
fi

# ---------- 2. subnet + VPC ----------
SUBNET_JSON=$(AWS ec2 describe-subnets --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[0].[VpcId,AvailabilityZone,AvailabilityZoneId,AvailableIpAddressCount]' --output text 2>/dev/null)
if [ -z "$SUBNET_JSON" ] || [ "$SUBNET_JSON" = "None" ]; then
  bad "subnet ${SUBNET_ID:-<unset>} not found"; echo "##### RESULT: cannot continue #####"; exit 1
fi
VPC_ID=$(echo "$SUBNET_JSON" | awk '{print $1}'); AZ=$(echo "$SUBNET_JSON" | awk '{print $2}')
AZ_ID=$(echo "$SUBNET_JSON" | awk '{print $3}'); FREE_IPS=$(echo "$SUBNET_JSON" | awk '{print $4}')
ok "subnet ${SUBNET_ID} in ${VPC_ID} (${AZ} / ${AZ_ID})"

CORES=$(( DRIVE_CORES + COMPUTE_CORES + FRONTEND_CORES ))
IPS_PER_NODE=$(( 1 + CORES )); [ -n "$MGMT_SUBNET_ID" ] && IPS_PER_NODE=$CORES
NEED_IPS=$(( IPS_PER_NODE * EXPECTED_NODES ))
if [ "$NEED_IPS" -gt 0 ] && [ "$FREE_IPS" -ge "$NEED_IPS" ]; then
  ok "subnet capacity: ${FREE_IPS} free IPs >= ${NEED_IPS} needed (${IPS_PER_NODE}/node x ${EXPECTED_NODES})"
elif [ "$NEED_IPS" -gt 0 ]; then
  bad "subnet has ${FREE_IPS} free IPs; ${EXPECTED_NODES} nodes need ${NEED_IPS} (${IPS_PER_NODE}/node)"
fi

# ---------- 3. VPC DNS attributes (SSM endpoints need BOTH) ----------
DNSS=$(AWS ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsSupport --query 'EnableDnsSupport.Value' --output text)
DNSH=$(AWS ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value' --output text)
if [ "$DNSS" = "True" ]; then ok "VPC DNS support enabled"
else bad "VPC DNS support DISABLED -- nothing resolves"
     fix "aws ec2 modify-vpc-attribute --region ${AWS_REGION} --vpc-id ${VPC_ID} --enable-dns-support"; fi
if [ "$DNSH" = "True" ]; then ok "VPC DNS hostnames enabled"
else warn "VPC DNS hostnames DISABLED (fresh-VPC default) -- SSM interface endpoints' private DNS will not work; enable it or rely on NAT for SSM"
     fix "aws ec2 modify-vpc-attribute --region ${AWS_REGION} --vpc-id ${VPC_ID} --enable-dns-hostnames"; fi

# ---------- 4. egress path (the IGW-without-public-IPs trap) ----------
RT=$(AWS ec2 describe-route-tables --filters "Name=association.subnet-id,Values=${SUBNET_ID}" \
  --query 'RouteTables[0].RouteTableId' --output text)
if [ "$RT" = "None" ] || [ -z "$RT" ]; then
  RT=$(AWS ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" "Name=association.main,Values=true" \
    --query 'RouteTables[0].RouteTableId' --output text)
  warn "subnet uses the VPC MAIN route table (${RT}) -- verify that is intentional"
fi
DEFROUTE=$(AWS ec2 describe-route-tables --route-table-ids "$RT" \
  --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`]|[0].[NatGatewayId,GatewayId,InstanceId,NetworkInterfaceId]' --output text 2>/dev/null)
NATGW=$(echo "$DEFROUTE" | awk '{print $1}'); GW=$(echo "$DEFROUTE" | awk '{print $2}')
NATINST=$(echo "$DEFROUTE" | awk '{print $3}'); NATENI=$(echo "$DEFROUTE" | awk '{print $4}')
EGRESS=none
if [ -n "$NATGW" ] && [ "$NATGW" != "None" ]; then
  ST=$(AWS ec2 describe-nat-gateways --nat-gateway-ids "$NATGW" --query 'NatGateways[0].State' --output text 2>/dev/null)
  if [ "$ST" = "available" ]; then ok "egress: 0.0.0.0/0 -> NAT gateway ${NATGW} (available)"; EGRESS=nat
  else bad "default route points at NAT gateway ${NATGW} but its state is '${ST}'"; fi
elif [ -n "$NATINST" ] && [ "$NATINST" != "None" ]; then
  ST=$(AWS ec2 describe-instances --instance-ids "$NATINST" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)
  if [ "$ST" = "running" ]; then ok "egress: 0.0.0.0/0 -> NAT instance ${NATINST} (running; mind its bandwidth under multi-node installs -- runbook §8)"; EGRESS=nat
  else bad "default route points at NAT instance ${NATINST} but it is '${ST:-gone}'"; fi
elif [ -n "$NATENI" ] && [ "$NATENI" != "None" ]; then
  ok "egress: 0.0.0.0/0 -> ENI ${NATENI} (NAT instance/appliance; mind its bandwidth under multi-node installs)"; EGRESS=nat
elif [ -n "$GW" ] && [ "$GW" != "None" ]; then
  case "$GW" in
    igw-*) bad "default route -> ${GW} (Internet Gateway) but this package launches nodes WITHOUT public IPs -- an IGW alone gives them ZERO egress (runbook §3.5). Use a NAT gateway, or expect repo/SSM/S3 downloads to fail"; EGRESS=igw
           fix "EIP=\$(aws ec2 allocate-address --region ${AWS_REGION} --query AllocationId --output text) && NAT=\$(aws ec2 create-nat-gateway --region ${AWS_REGION} --subnet-id <A-PUBLIC-SUBNET> --allocation-id \$EIP --query NatGateway.NatGatewayId --output text) && aws ec2 wait nat-gateway-available --region ${AWS_REGION} --nat-gateway-ids \$NAT && aws ec2 replace-route --region ${AWS_REGION} --route-table-id ${RT} --destination-cidr-block 0.0.0.0/0 --nat-gateway-id \$NAT" ;;
    *)     warn "default route -> ${GW}; verify nodes can reach package repos, SSM, and S3 through it"; EGRESS=other ;;
  esac
else
  warn "no default route on ${RT} -- no-internet subnet: needs SSM endpoints + S3 endpoint, AND an AMI with build deps baked (repos unreachable)"; EGRESS=none
fi

# ---------- 5. S3 path (WEKA tarball + SSM agent RPM) ----------
S3EP=$(AWS ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${VPC_ID}" \
  "Name=service-name,Values=com.amazonaws.${AWS_REGION}.s3" \
  --query "VpcEndpoints[?State=='available']|[0].VpcEndpointId" --output text 2>/dev/null)
[ "$S3EP" = "None" ] && S3EP=""
if [ -n "$S3EP" ]; then
  S3RTS=$(AWS ec2 describe-vpc-endpoints --vpc-endpoint-ids "$S3EP" \
    --query 'VpcEndpoints[0].RouteTableIds' --output text 2>/dev/null)
  if echo "$S3RTS" | grep -qw "$RT"; then ok "S3 gateway endpoint present and on the subnet's route table"
  else warn "S3 gateway endpoint exists but is NOT associated with ${RT} -- S3 traffic will use the default route instead"
       fix "aws ec2 modify-vpc-endpoint --region ${AWS_REGION} --vpc-endpoint-id ${S3EP} --add-route-table-ids ${RT}"; fi
elif [ "$EGRESS" = "nat" ]; then
  ok "no S3 gateway endpoint, but NAT covers S3 (endpoint recommended: free + private)"
else
  bad "no S3 path: no gateway endpoint on ${RT} and no NAT -- nodes cannot fetch the WEKA tarball"
  fix "aws ec2 create-vpc-endpoint --region ${AWS_REGION} --vpc-id ${VPC_ID} --service-name com.amazonaws.${AWS_REGION}.s3 --route-table-ids ${RT}"
fi

# ---------- 6. SSM path ----------
if [ "$EGRESS" = "nat" ]; then
  ok "SSM control plane reachable via NAT"
else
  MISSING=""
  for svc in ssm ssmmessages ec2messages; do
    EP=$(AWS ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${VPC_ID}" \
      "Name=service-name,Values=com.amazonaws.${AWS_REGION}.${svc}" \
      --query "VpcEndpoints[?State=='available']|[0].VpcEndpointId" --output text 2>/dev/null)
    [ -n "$EP" ] && [ "$EP" != "None" ] || MISSING="$MISSING $svc"
  done
  if [ -z "$MISSING" ]; then ok "SSM interface endpoints present (ssm, ssmmessages, ec2messages)"
  else bad "no NAT and missing SSM interface endpoint(s):${MISSING} -- nodes will never register with SSM (create-infrastructure.sh can add them)"
       for svc in $MISSING; do
         fix "aws ec2 create-vpc-endpoint --region ${AWS_REGION} --vpc-id ${VPC_ID} --vpc-endpoint-type Interface --service-name com.amazonaws.${AWS_REGION}.${svc} --subnet-ids ${SUBNET_ID} --security-group-ids ${SG_ENA} --private-dns-enabled"
       done
       fix "(endpoint SG must allow 443 from the node SGs -- ${SG_ENA:-your ENA SG} works if the nodes use it too)"; fi
fi

# ---------- 7. security groups ----------
check_selfref() {  # $1=sg  $2=label  $3=direction-query
  local rules
  rules=$(AWS ec2 describe-security-groups --group-ids "$1" --query "$3" --output json 2>/dev/null)
  echo "$rules" | grep -q "\"GroupId\": \"$1\"" && echo yes || echo no
}
for pair in "SG_ENA:${SG_ENA}" "SG_MGMT:${SG_MGMT}" "SG_EFA:${SG_EFA}"; do
  label="${pair%%:*}"; sg="${pair##*:}"
  [ -z "$sg" ] && continue
  SGVPC=$(AWS ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].VpcId' --output text 2>/dev/null)
  if [ -z "$SGVPC" ] || [ "$SGVPC" = "None" ]; then bad "${label} ${sg} not found"; continue; fi
  if [ "$label" = "SG_MGMT" ] && [ -n "$MGMT_SUBNET_ID" ]; then
    MV=$(AWS ec2 describe-subnets --subnet-ids "$MGMT_SUBNET_ID" --query 'Subnets[0].VpcId' --output text 2>/dev/null)
    [ "$SGVPC" = "$MV" ] && ok "${label} ${sg} is in the mgmt subnet's VPC" || bad "${label} ${sg} is in ${SGVPC}, not the mgmt subnet's VPC ${MV}"
  else
    [ "$SGVPC" = "$VPC_ID" ] && ok "${label} ${sg} is in ${VPC_ID}" || bad "${label} ${sg} is in ${SGVPC}, not ${VPC_ID}"
  fi
  IN=$(check_selfref "$sg" "$label" "SecurityGroups[0].IpPermissions[?IpProtocol=='-1'].UserIdGroupPairs")
  if [ "$IN" = "yes" ]; then ok "${label} self-references ALL inbound traffic"
  else
    [ "$label" = "SG_EFA" ] && bad "${label} does NOT self-reference all inbound traffic -- EFA requires it" \
                             || bad "${label} does NOT self-reference all inbound traffic -- WEKA node-to-node traffic will be blocked"
    fix "aws ec2 authorize-security-group-ingress --region ${AWS_REGION} --group-id ${sg} --protocol -1 --source-group ${sg}"
  fi
  if [ "$label" = "SG_EFA" ]; then
    OUT=$(check_selfref "$sg" "$label" "SecurityGroups[0].IpPermissionsEgress[?IpProtocol=='-1'].UserIdGroupPairs")
    ALLOUT=$(AWS ec2 describe-security-groups --group-ids "$sg" \
      --query "SecurityGroups[0].IpPermissionsEgress[?IpProtocol=='-1'].IpRanges[?CidrIp=='0.0.0.0/0']|[0]" --output text 2>/dev/null)
    if [ "$OUT" = "yes" ] || [ -n "$ALLOUT" ]; then ok "${label} egress covers self-referenced traffic"
    else warn "${label} egress may not cover group-to-group traffic -- EFA needs all outbound to itself"
         fix "aws ec2 authorize-security-group-egress --region ${AWS_REGION} --group-id ${sg} --protocol -1 --source-group ${sg}"; fi
  fi
done

# ---------- 8. instance profile ----------
if [ -n "$INSTANCE_PROFILE_ARN" ]; then
  PNAME="${INSTANCE_PROFILE_ARN##*/}"
  ROLE=$(aws iam get-instance-profile --instance-profile-name "$PNAME" --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null)
  if [ -n "$ROLE" ] && [ "$ROLE" != "None" ]; then
    ok "instance profile ${PNAME} exists (role ${ROLE})"
    if aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null | grep -q AmazonSSMManagedInstanceCore; then
      ok "role has AmazonSSMManagedInstanceCore"
    else warn "role ${ROLE} lacks AmazonSSMManagedInstanceCore -- required for SSM registration unless an equivalent inline policy grants it"
         fix "aws iam attach-role-policy --role-name ${ROLE} --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"; fi
    if aws iam list-role-policies --role-name "$ROLE" --output text 2>/dev/null | grep -q .; then
      MATCH=$(for p in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames' --output text); do
        aws iam get-role-policy --role-name "$ROLE" --policy-name "$p" --output json; done | grep -c "$CLUSTER_NAME")
      [ "$MATCH" -gt 0 ] && ok "inline policy mentions cluster name '${CLUSTER_NAME}' (tag-condition three-way match)" \
        || warn "no inline policy mentions '${CLUSTER_NAME}' -- if the WEKA instance policy's SendCommand tag condition names a different cluster, install fails with AccessDenied (runbook §4)"
    fi
  else bad "instance profile ${PNAME} not found"; fi
else warn "INSTANCE_PROFILE_ARN not set -- skipping IAM checks"
fi

# ---------- 9. AMI ----------
if [ -n "$AMI_ID" ]; then
  AMIQ=$(AWS ec2 describe-images --image-ids "$AMI_ID" --query 'Images[0].[Name,RootDeviceName,Architecture]' --output text 2>/dev/null)
  if [ -n "$AMIQ" ] && [ "$AMIQ" != "None" ]; then
    ok "AMI ${AMI_ID}: $(echo "$AMIQ" | awk '{print $1}') (root $(echo "$AMIQ" | awk '{print $2}'), $(echo "$AMIQ" | awk '{print $3}'))"
  else bad "AMI ${AMI_ID} not found/visible in this account+region"; fi
else warn "AMI_ID not set -- skipping AMI check"
fi

# ---------- 10. instance type offered in this AZ ----------
if [ -n "$INSTANCE_TYPE" ]; then
  OFF=$(AWS ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=instance-type,Values=${INSTANCE_TYPE}" "Name=location,Values=${AZ}" \
    --query 'InstanceTypeOfferings[0].InstanceType' --output text 2>/dev/null)
  [ "$OFF" = "$INSTANCE_TYPE" ] && ok "${INSTANCE_TYPE} is offered in ${AZ}" \
    || bad "${INSTANCE_TYPE} is NOT offered in ${AZ} -- pick a subnet in an AZ that has it"
fi

# ---------- 11. capacity reservation ----------
if [ -n "$CAPACITY_RESERVATION_ID" ]; then
  CR=$(AWS ec2 describe-capacity-reservations --capacity-reservation-ids "$CAPACITY_RESERVATION_ID" \
    --query 'CapacityReservations[0].[State,AvailabilityZone,InstanceType,AvailableInstanceCount]' --output text 2>/dev/null)
  if [ -z "$CR" ] || [ "$CR" = "None" ]; then bad "capacity reservation ${CAPACITY_RESERVATION_ID} not found"
  else
    CRST=$(echo "$CR" | awk '{print $1}'); CRAZ=$(echo "$CR" | awk '{print $2}')
    CRTYPE=$(echo "$CR" | awk '{print $3}'); CRAVL=$(echo "$CR" | awk '{print $4}')
    [ "$CRST" = "active" ] && ok "capacity reservation active" || warn "capacity reservation state: ${CRST}"
    [ "$CRAZ" = "$AZ" ] && ok "reservation AZ matches subnet (${AZ})" || bad "reservation is in ${CRAZ} but subnet is in ${AZ}"
    [ "$CRTYPE" = "$INSTANCE_TYPE" ] && ok "reservation instance type matches" || bad "reservation is for ${CRTYPE}, config says ${INSTANCE_TYPE}"
    [ "$CRAVL" -ge "$EXPECTED_NODES" ] && ok "reservation capacity: ${CRAVL} available >= ${EXPECTED_NODES}" \
      || warn "reservation has ${CRAVL} available; EXPECTED_NODES=${EXPECTED_NODES}"
  fi
fi

# ---------- 12. WEKA tarball ----------
if [ -n "$WEKA_INSTALL_S3" ]; then
  B="${WEKA_INSTALL_S3#s3://}"; BUCKET="${B%%/*}"; KEY="${B#*/}"
  if AWS s3api head-object --bucket "$BUCKET" --key "$KEY" >/dev/null 2>&1; then
    ok "WEKA tarball present: ${WEKA_INSTALL_S3}"
  else warn "cannot HEAD ${WEKA_INSTALL_S3} with YOUR credentials -- verify the object exists and that the INSTANCE role can read it"; fi
fi

echo "##### RESULT: ${PASS} pass / ${WARN} warn / ${FAIL} fail #####"
[ "$FAIL" -eq 0 ]
