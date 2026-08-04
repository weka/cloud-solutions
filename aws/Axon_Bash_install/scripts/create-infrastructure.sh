#!/usr/bin/env bash
#
# create-infrastructure.sh  (OPTIONAL -- greenfield environments only)
#
# Most deployments should use EXISTING VPC infrastructure and skip this
# script entirely (see RUNBOOK §3). For environments that lack the pieces,
# this creates the minimum set inside an existing VPC:
#
#   - a cluster subnet in the capacity reservation's AZ
#   - ENA security group (self-referencing) and, optionally, an EFA SG
#     (self-referencing ALL traffic, both directions)
#   - optionally: SSM interface endpoints (for no-internet subnets)
#   - IAM role + instance profile (SSM core + the WEKA instance policy)
#
# It does NOT create a VPC, IGW, NAT, or S3 endpoint. Prints the resource
# ids in the exact form generate-launch-template.sh expects.
#
set -euo pipefail

###############################################################################
##                        CUSTOMER CONFIGURATION                             ##
###############################################################################

AWS_REGION="us-east-1"        # CHANGEME
VPC_ID=""                     # CHANGEME: existing VPC
EXISTING_SUBNET_ID=""         # OPTIONAL: use this existing subnet and skip subnet
                              #   creation (SUBNET_CIDR/AVAILABILITY_ZONE_ID then unused)
SUBNET_CIDR=""                # CHANGEME (unless EXISTING_SUBNET_ID): free CIDR inside the VPC (>= /24 recommended)
AVAILABILITY_ZONE_ID=""       # CHANGEME (unless EXISTING_SUBNET_ID): zone ID of the capacity reservation (e.g. use1-az1)
CLUSTER_NAME="weka-cluster1"  # CHANGEME: used for names + tags
ACCOUNT_ID=""                 # CHANGEME: AWS account id (for the IAM policy)

CREATE_EFA_SG=true            # false for non-EFA (non-GPU) instance types
CREATE_SSM_ENDPOINTS=false    # true if the subnet has no path to SSM (endpoints
ENDPOINT_SUBNET_ID=""         #   are created in this subnet; may differ from the
                              #   cluster subnet, e.g. a parent-region subnet)
ROUTE_TABLE_ID=""             # optional: associate the new subnet with this route table
POLICY_FILE="iam/instance-policy.json"   # path to the policy template from this package

###############################################################################
# weka.conf overlay -- if present, values there OVERRIDE the defaults above.
# Workstation: ./weka.conf (package root). Nodes: /tmp/weka.conf (shipped by
# deploy.sh). See RUNBOOK §4.
for _c in ./weka.conf /tmp/weka.conf; do [ -f "$_c" ] && . "$_c" || true; done

###############################################################################

die() { echo "FATAL: $*" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || die "aws CLI is required"
REQUIRED="VPC_ID ACCOUNT_ID"
[ -n "$EXISTING_SUBNET_ID" ] || REQUIRED="$REQUIRED SUBNET_CIDR AVAILABILITY_ZONE_ID"
for v in $REQUIRED; do
  [ -n "${!v}" ] || die "$v is not set -- fill in the CUSTOMER CONFIGURATION block"
done
TAGS="Key=weka-cluster,Value=${CLUSTER_NAME}"

echo "== subnet =="
if [ -n "$EXISTING_SUBNET_ID" ]; then
  SUBNET_ID="$EXISTING_SUBNET_ID"
  aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$SUBNET_ID" \
    --query 'Subnets[0].VpcId' --output text | grep -q "^${VPC_ID}$" \
    || die "EXISTING_SUBNET_ID ${SUBNET_ID} is not in ${VPC_ID}"
  echo "   using existing $SUBNET_ID (creation skipped)"
else
  SUBNET_ID=$(aws ec2 create-subnet --region "$AWS_REGION" --vpc-id "$VPC_ID" \
    --cidr-block "$SUBNET_CIDR" --availability-zone-id "$AVAILABILITY_ZONE_ID" \
    --tag-specifications "ResourceType=subnet,Tags=[{${TAGS}},{Key=Name,Value=${CLUSTER_NAME}-subnet}]" \
    --query 'Subnet.SubnetId' --output text)
  echo "   $SUBNET_ID ($SUBNET_CIDR in $AVAILABILITY_ZONE_ID)"
fi
if [ -n "$ROUTE_TABLE_ID" ]; then
  aws ec2 associate-route-table --region "$AWS_REGION" \
    --route-table-id "$ROUTE_TABLE_ID" --subnet-id "$SUBNET_ID" >/dev/null
  echo "   associated with $ROUTE_TABLE_ID"
fi

echo "== ENA security group =="
SG_ENA=$(aws ec2 create-security-group --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --group-name "${CLUSTER_NAME}-ena" --description "WEKA mgmt+data - self-referencing" \
  --tag-specifications "ResourceType=security-group,Tags=[{${TAGS}}]" \
  --query GroupId --output text)
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
  --group-id "$SG_ENA" --protocol -1 --source-group "$SG_ENA" >/dev/null
echo "   $SG_ENA"

SG_EFA=""
if [ "$CREATE_EFA_SG" = "true" ]; then
  echo "== EFA security group =="
  SG_EFA=$(aws ec2 create-security-group --region "$AWS_REGION" --vpc-id "$VPC_ID" \
    --group-name "${CLUSTER_NAME}-efa" --description "EFA - self-referencing all traffic" \
    --tag-specifications "ResourceType=security-group,Tags=[{${TAGS}}]" \
    --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
    --group-id "$SG_EFA" --protocol -1 --source-group "$SG_EFA" >/dev/null
  aws ec2 authorize-security-group-egress --region "$AWS_REGION" \
    --group-id "$SG_EFA" --protocol -1 --source-group "$SG_EFA" >/dev/null
  echo "   $SG_EFA"
fi

if [ "$CREATE_SSM_ENDPOINTS" = "true" ]; then
  echo "== SSM interface endpoints =="
  [ -n "$ENDPOINT_SUBNET_ID" ] || ENDPOINT_SUBNET_ID="$SUBNET_ID"
  SG_VPCE=$(aws ec2 create-security-group --region "$AWS_REGION" --vpc-id "$VPC_ID" \
    --group-name "${CLUSTER_NAME}-endpoints" --description "443 from VPC for interface endpoints" \
    --query GroupId --output text)
  VPC_CIDR=$(aws ec2 describe-vpcs --region "$AWS_REGION" --vpc-ids "$VPC_ID" \
    --query 'Vpcs[0].CidrBlock' --output text)
  aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
    --group-id "$SG_VPCE" --protocol tcp --port 443 --cidr "$VPC_CIDR" >/dev/null
  for svc in ssm ssmmessages ec2messages secretsmanager; do
    aws ec2 create-vpc-endpoint --region "$AWS_REGION" --vpc-id "$VPC_ID" \
      --vpc-endpoint-type Interface --service-name "com.amazonaws.${AWS_REGION}.${svc}" \
      --subnet-ids "$ENDPOINT_SUBNET_ID" --security-group-ids "$SG_VPCE" \
      --private-dns-enabled --query 'VpcEndpoint.VpcEndpointId' --output text
  done
  echo "   (endpoints take a few minutes to become 'available')"
fi

echo "== IAM role + instance profile =="
ROLE="${CLUSTER_NAME}-instance-role"
PROFILE="${CLUSTER_NAME}-instance-profile"
[ -f "$POLICY_FILE" ] || die "policy file not found: $POLICY_FILE (run from the package root)"
sed -e "s/ACCOUNT_ID/${ACCOUNT_ID}/g" -e "s/\"CLUSTER_NAME\"/\"${CLUSTER_NAME}\"/g" -e "s/p6b300-weka/${CLUSTER_NAME}/g" \
  -e "s/us-east-1/${AWS_REGION}/g" "$POLICY_FILE" > /tmp/weka-instance-policy-filled.json
aws iam create-role --role-name "$ROLE" --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --query 'Role.Arn' --output text
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam put-role-policy --role-name "$ROLE" --policy-name "${CLUSTER_NAME}-weka" \
  --policy-document file:///tmp/weka-instance-policy-filled.json
PROFILE_ARN=$(aws iam create-instance-profile --instance-profile-name "$PROFILE" \
  --query 'InstanceProfile.Arn' --output text)
aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE"
echo "   $PROFILE_ARN"

cat <<SUMMARY

== paste into generate-launch-template.sh ==
SUBNET_ID="${SUBNET_ID}"
SG_ENA="${SG_ENA}"
SG_EFA="${SG_EFA}"
INSTANCE_PROFILE_ARN="${PROFILE_ARN}"
CLUSTER_NAME="${CLUSTER_NAME}"

Reminders: the WEKA distro bucket statements in the IAM policy still carry
placeholder bucket names (edit or remove), and the subnet needs an S3 path
(gateway endpoint on its route table, or NAT) for downloads.
SUMMARY
