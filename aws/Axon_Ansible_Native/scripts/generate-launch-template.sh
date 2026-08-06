#!/usr/bin/env bash
#
# generate-launch-template.sh
#
# Generates the EC2 launch template (or a merge fragment for an EXISTING
# customer launch template) for a WEKA converged deployment, driven by the
# selected instance type's actual capabilities:
#
#   - queries describe-instance-types for network cards, per-card ENI limits,
#     EFA support and instance storage
#   - validates the instance type meets WEKA minimums (local NVMe, enough
#     ENI capacity for the configured core carve)
#   - computes the ENI layout: 1 mgmt ENI + N data-plane ENIs (one per WEKA
#     core: DRIVE+COMPUTE+FRONTEND) + EFA-only interfaces on GPU platforms
#
# Runs on an operator workstation. Requires: aws CLI (authenticated), python3.
# Nothing is created in AWS unless CREATE_IN_AWS=true.
#
set -euo pipefail

###############################################################################
##                          CUSTOMER CONFIGURATION                           ##
##  Capture of the customer's EXISTING environment -- no resources are       ##
##  created by this script. All CHANGEME values are required.                ##
###############################################################################

AWS_REGION="us-east-1"            # CHANGEME: deployment region
INSTANCE_TYPE="p6-b300.48xlarge"  # CHANGEME: any type with local NVMe + enough ENIs
AMI_ID=""                         # CHANGEME: customer AMI (kernel <= 6.8 for WEKA 4.4.x)
SUBNET_ID=""                      # CHANGEME: existing subnet, same AZ as capacity reservation
MGMT_SUBNET_ID=""                 # optional: separate subnet for the mgmt ENI (same VPC + AZ);
                                  # empty = mgmt shares SUBNET_ID
SG_ENA=""                         # CHANGEME: existing SG for mgmt + WEKA data (self-referencing)
SG_EFA=""                         # CHANGEME if EFA in use: existing SG, self-referencing ALL traffic
SG_MGMT=""                        # optional: separate SG for the mgmt ENI; empty = SG_ENA
INSTANCE_PROFILE_ARN=""           # CHANGEME: arn:aws:iam::<acct>:instance-profile/<name>
CLUSTER_NAME="weka-cluster1"      # CHANGEME: must match installer CLUSTER_NAME + IAM tag condition

# ---- WEKA core carve: MUST MATCH the day-0 installer values ----------------
# Data-plane ENI count is derived from these (one ENI per WEKA core).
DRIVE_CORES=4
COMPUTE_CORES=8
FRONTEND_CORES=2

# ---- sizing hints (validation only) ----------------------------------------
EXPECTED_NODES=8                  # used to sanity-check subnet free IP capacity

# ---- overrides ("auto" = derived from instance-type capabilities) ----------
EFA_COUNT="auto"                  # auto: MaximumEfaInterfaces on GPU types, else 0
EFA_CARD_START=1                  # first network card for EFA-only ENIs on multi-card types
ROOT_VOLUME_GB=500
ROOT_VOLUME_TYPE="gp3"
WEKA_OPT_VOLUME_GB=0              # dedicated EBS volume for /opt/weka: 0 = share root; N = N GiB;
                                  # "auto" = 48 + 10/WEKA-core (matches the official WEKA Terraform sizing)
USER_DATA_FILE=""                 # optional: shell script baked into the template as
                                  #   instance user data (e.g. scripts/userdata-el.sh --
                                  #   SSM agent + SELinux for RHEL-family AMIs)
PLACEMENT_GROUP=""                # optional: name of an EXISTING placement group for the
                                  #   backends (lower/more consistent inter-node latency).
                                  #   empty = no placement group (default). NB: cluster-strategy
                                  #   groups raise InsufficientInstanceCapacity odds on
                                  #   large/scarce types; capacity blocks/ODCRs manage their own
                                  #   placement and generally should NOT set this.
LAUNCH_TEMPLATE_NAME=""           # empty = weka-<cluster>-<sanitized instance type>
OUTPUT_DIR="."                    # where the JSON files are written
CREATE_IN_AWS=false               # true: also run create-launch-template

###############################################################################
# weka.conf overlay -- if present, values there OVERRIDE the defaults above.
# Workstation: ./weka.conf (package root). Nodes: /tmp/weka.conf (shipped by
# deploy.sh). See RUNBOOK §4.
for _c in ./weka.conf /tmp/weka.conf; do [ -f "$_c" ] && . "$_c" || true; done

###############################################################################
##                                 LOGIC                                     ##
###############################################################################

die() { echo "FATAL: $*" >&2; exit 1; }
command -v aws >/dev/null 2>&1     || die "aws CLI is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# 'describe' mode: capability report only -- no CHANGEMEs needed beyond the
# region and instance type. Usage: generate-launch-template.sh describe [type]
MODE="${1:-generate}"
[ -n "${2:-}" ] && INSTANCE_TYPE="$2"
if [ "$MODE" != "describe" ]; then
  for v in AMI_ID SUBNET_ID SG_ENA INSTANCE_PROFILE_ARN; do
    [ -n "${!v}" ] || die "$v is not set -- fill in the CUSTOMER CONFIGURATION block (or run: $0 describe <instance-type>)"
  done
fi

echo "== querying capabilities of ${INSTANCE_TYPE} in ${AWS_REGION} =="
CAPS=$(aws ec2 describe-instance-types --region "$AWS_REGION" \
  --instance-types "$INSTANCE_TYPE" --output json) \
  || die "describe-instance-types failed for ${INSTANCE_TYPE}"

if [ "$MODE" = "describe" ]; then
  export CAPS INSTANCE_TYPE
  python3 <<'DESCEOF'
import json, os
caps = json.loads(os.environ["CAPS"])["InstanceTypes"][0]
itype   = os.environ["INSTANCE_TYPE"]
net     = caps["NetworkInfo"]
cards   = net.get("NetworkCards", [])
n_cards = net.get("MaximumNetworkCards", 1)
enis    = net["MaximumNetworkInterfaces"]
efa_ok  = net.get("EfaSupported", False)
efa_max = net.get("EfaInfo", {}).get("MaximumEfaInterfaces", 0) if efa_ok else 0
gpu     = caps.get("GpuInfo")
storage = caps.get("InstanceStorageInfo")
cores   = caps["VCpuInfo"].get("DefaultCores", caps["VCpuInfo"]["DefaultVCpus"] // 2)
mem_gb  = caps["MemoryInfo"]["SizeInMiB"] // 1024

print(f"\n== WEKA deployment capability report: {itype} ==")
if not storage or not storage.get("Disks"):
    print("   UNSUITABLE: no local instance-store NVMe (WEKA backends require it)")
    raise SystemExit(0)
disks = storage["Disks"]
print(f"   instance storage : {sum(d['Count'] for d in disks)} x {disks[0]['SizeInGB']} GB NVMe")
print(f"   physical cores   : {cores}   memory: {mem_gb} GiB")
print(f"   GPUs             : " + (f"{gpu['Gpus'][0]['Count']} x {gpu['Gpus'][0]['Name']}" if gpu else "none"))
print(f"   network          : {n_cards} card(s), {enis} ENIs max, EFA={'yes (' + str(efa_max) + ')' if efa_ok else 'no'}")

efa_auto = efa_max if (efa_ok and gpu) else 0
# data ENIs pack round-robin across cards (multiple per card when cores > cards),
# bounded by the per-card and total ENI limits
slots = sum(c["MaximumNetworkInterfaces"] for c in cards) if cards else enis
max_carve = min(enis, slots) - 1 - efa_auto
max_carve = min(max_carve, cores - 1)
print(f"\n   ENI budget       : {enis} = 1 mgmt + {efa_auto} EFA (auto) + up to {max_carve} WEKA data ENIs")
print(f"   => max core carve: DRIVE+COMPUTE+FRONTEND <= {max_carve}" + ("  (installer minimum: 3)" if max_carve >= 3 else "  -- BELOW the 3-NIC minimum: type unsuitable"))
if max_carve >= 3:
    d = max(1, round(max_carve * 2 / 7)); f = max(1, round(max_carve / 7)); c = max(1, max_carve - d - f)
    print(f"   suggested start  : DRIVE_CORES={d} COMPUTE_CORES={c} FRONTEND_CORES={f}"
          f"   (1:2:0.5 shape -- size properly with WEKA for production)")
    print(f"   /opt/weka (auto) : {48 + 10 * max_carve} GB at the max carve")
DESCEOF
  exit 0
fi

AMI_INFO=$(aws ec2 describe-images --region "$AWS_REGION" --image-ids "$AMI_ID" \
  --query 'Images[0].{root:RootDeviceName,name:Name}' --output json) \
  || die "describe-images failed for ${AMI_ID}"

SUBNET_INFO=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[0].{az:AvailabilityZone,azId:AvailabilityZoneId,free:AvailableIpAddressCount,vpc:VpcId}' \
  --output json) || die "describe-subnets failed for ${SUBNET_ID}"

MGMT_SUBNET_INFO="null"
if [ -n "$MGMT_SUBNET_ID" ]; then
  MGMT_SUBNET_INFO=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$MGMT_SUBNET_ID" \
    --query 'Subnets[0].{az:AvailabilityZone,azId:AvailabilityZoneId,free:AvailableIpAddressCount,vpc:VpcId}' \
    --output json) || die "describe-subnets failed for ${MGMT_SUBNET_ID}"
fi

SG_EFA_RULES="[]"
if [ -n "$SG_EFA" ]; then
  SG_EFA_RULES=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$SG_EFA" \
    --query 'SecurityGroups[0].IpPermissions' --output json) || die "describe-security-groups failed for ${SG_EFA}"
fi

# optional placement group: must already exist (this script creates nothing)
if [ -n "${PLACEMENT_GROUP:-}" ]; then
  PG_STRATEGY=$(aws ec2 describe-placement-groups --region "$AWS_REGION" \
    --group-names "$PLACEMENT_GROUP" --query 'PlacementGroups[0].Strategy' --output text 2>/dev/null) \
    || die "placement group '$PLACEMENT_GROUP' not found in $AWS_REGION
  fix: aws ec2 create-placement-group --region $AWS_REGION --group-name $PLACEMENT_GROUP --strategy cluster"
  echo "   placement group: $PLACEMENT_GROUP (strategy: $PG_STRATEGY)"
fi

export CAPS AMI_INFO SUBNET_INFO MGMT_SUBNET_INFO SG_EFA_RULES PLACEMENT_GROUP
export INSTANCE_TYPE AMI_ID SUBNET_ID MGMT_SUBNET_ID SG_ENA SG_EFA SG_MGMT INSTANCE_PROFILE_ARN CLUSTER_NAME
export DRIVE_CORES COMPUTE_CORES FRONTEND_CORES EXPECTED_NODES
export EFA_COUNT EFA_CARD_START ROOT_VOLUME_GB ROOT_VOLUME_TYPE WEKA_OPT_VOLUME_GB LAUNCH_TEMPLATE_NAME OUTPUT_DIR
if [ -n "$USER_DATA_FILE" ]; then
  [ -f "$USER_DATA_FILE" ] || { echo "FATAL: USER_DATA_FILE '$USER_DATA_FILE' not found" >&2; exit 1; }
fi
export USER_DATA_FILE

python3 <<'PYEOF'
import json, os, sys

caps   = json.loads(os.environ["CAPS"])["InstanceTypes"][0]
ami    = json.loads(os.environ["AMI_INFO"])
subnet = json.loads(os.environ["SUBNET_INFO"])
mgmt_subnet_id = os.environ.get("MGMT_SUBNET_ID", "")
mgmt_subnet = json.loads(os.environ.get("MGMT_SUBNET_INFO", "null"))
sg_mgmt = os.environ.get("SG_MGMT", "")
efa_rules = json.loads(os.environ["SG_EFA_RULES"])
env = os.environ

fail = []
warn = []

itype     = env["INSTANCE_TYPE"]
cluster   = env["CLUSTER_NAME"]
sg_ena    = env["SG_ENA"]
sg_efa    = env["SG_EFA"]
subnet_id = env["SUBNET_ID"]
cores     = int(env["DRIVE_CORES"]) + int(env["COMPUTE_CORES"]) + int(env["FRONTEND_CORES"])
nodes     = int(env["EXPECTED_NODES"])

net       = caps["NetworkInfo"]
cards     = sorted(net.get("NetworkCards", []), key=lambda c: c["NetworkCardIndex"])
n_cards   = net.get("MaximumNetworkCards", 1)
total_max = net["MaximumNetworkInterfaces"]
efa_ok    = net.get("EfaSupported", False)
efa_max   = net.get("EfaInfo", {}).get("MaximumEfaInterfaces", 0) if efa_ok else 0
has_gpu   = bool(caps.get("GpuInfo"))
storage   = caps.get("InstanceStorageInfo")

# ---- minimum requirements -------------------------------------------------
if not storage or not storage.get("Disks"):
    fail.append(f"{itype} has NO local instance storage -- WEKA backends require local NVMe")
else:
    disks = storage["Disks"]
    total_gb = sum(d["SizeInGB"] * d["Count"] for d in disks)
    print(f"[ok] instance storage: {sum(d['Count'] for d in disks)} disk(s), {total_gb} GB total")

# ---- split management subnet (optional) -------------------------------------
# Same-VPC split is expressed in the launch template directly. DIFFERENT-VPC
# data subnets are supported via multi-VPC ENI attachments (same account +
# AZ, post-launch attach): the template then contains only the launch-VPC
# ENIs and a data-ENI attachment plan is emitted for attach-data-enis.sh.
cross_vpc = False
if mgmt_subnet_id:
    if mgmt_subnet["az"] != subnet["az"]:
        fail.append(f"MGMT_SUBNET_ID is in {mgmt_subnet['az']} but the data subnet is in {subnet['az']} -- "
                    "ALL of an instance's ENIs must share one AZ (multi-VPC attachments included)")
    elif mgmt_subnet["vpc"] != subnet["vpc"]:
        cross_vpc = True
        print(f"[ok] CROSS-VPC layout: launch/mgmt {mgmt_subnet_id} (VPC {mgmt_subnet['vpc']}), "
              f"data {subnet_id} (VPC {subnet['vpc']}) -- data ENIs will be attached post-launch")
        if not sg_mgmt:
            fail.append("cross-VPC layout requires SG_MGMT (a security group in the LAUNCH/mgmt VPC) -- "
                        "SG_ENA belongs to the data VPC and cannot be used on the mgmt ENI")
        if mgmt_subnet["free"] < nodes:
            warn.append(f"mgmt subnet has {mgmt_subnet['free']} free IPs; {nodes} nodes need {nodes}")
    else:
        print(f"[ok] split management subnet: mgmt {mgmt_subnet_id} ({mgmt_subnet['az']}), data {subnet_id}")
        if mgmt_subnet["free"] < nodes:
            warn.append(f"mgmt subnet has {mgmt_subnet['free']} free IPs; {nodes} nodes need {nodes}")

# ---- EFA plan ---------------------------------------------------------------
efa_count = env["EFA_COUNT"]
if efa_count == "auto":
    efa_count = efa_max if (efa_ok and has_gpu) else 0
    print(f"[ok] EFA_COUNT=auto -> {efa_count} "
          f"(EfaSupported={efa_ok}, MaximumEfaInterfaces={efa_max}, GPU={'yes' if has_gpu else 'no'})")
else:
    efa_count = int(efa_count)
    if efa_count > efa_max:
        fail.append(f"EFA_COUNT={efa_count} exceeds the type's MaximumEfaInterfaces={efa_max}")
if efa_count > 0 and not sg_efa:
    fail.append("EFA interfaces requested but SG_EFA is not set")

# ---- SG_EFA self-referencing check -----------------------------------------
if sg_efa:
    self_ref = any(
        p.get("IpProtocol") == "-1"
        and any(g.get("GroupId") == sg_efa for g in p.get("UserIdGroupPairs", []))
        for p in efa_rules)
    if self_ref: print(f"[ok] {sg_efa} has a self-referencing all-traffic ingress rule")
    else: warn.append(f"{sg_efa} does not appear to be self-referencing for ALL traffic -- EFA requires it")

# ---- ENI layout -------------------------------------------------------------
# slot bookkeeping per card: card_used[idx] counts device indexes consumed
card_max = {c["NetworkCardIndex"]: c["MaximumNetworkInterfaces"] for c in cards} \
           if cards else {0: total_max}
card_used = {i: 0 for i in card_max}
enis = []

def take(card, iface_type, desc, groups, subnet=None):
    dev = card_used[card]
    card_used[card] += 1
    e = {"NetworkCardIndex": card, "DeviceIndex": dev, "InterfaceType": iface_type,
         "Description": desc, "Groups": groups, "SubnetId": subnet or subnet_id,
         "DeleteOnTermination": True}
    if iface_type == "interface":
        e["AssociatePublicIpAddress"] = False
    enis.append(e)

# mgmt: always card 0 / dev 0 (optionally on its own subnet / SG)
take(0, "interface", "mgmt (nci0/dev0) - management, default route - NOT weka data",
     [sg_mgmt or sg_ena], subnet=(mgmt_subnet_id or None))

# EFA-only interfaces
efa_start = int(env["EFA_CARD_START"])
if efa_count > 0:
    if n_cards > 1:
        avail = [i for i in sorted(card_max) if i >= efa_start]
        if efa_count > len(avail):
            fail.append(f"EFA_COUNT={efa_count} > cards available from index {efa_start} ({len(avail)}) -- "
                        "multi-EFA-per-card layouts need explicit review; lower EFA_COUNT or adjust EFA_CARD_START")
        else:
            for i in avail[:efa_count]:
                take(i, "efa-only", f"efa (nci{i}/dev{card_used[i]}) - GPU/NCCL, no IP", [sg_efa])
    else:
        for _ in range(efa_count):
            take(0, "efa-only", f"efa (nci0/dev{card_used[0]}) - GPU/NCCL, no IP", [sg_efa])

# data-plane ENIs: one per WEKA core. Cross-VPC: recorded in the attachment
# plan instead of the template (launch templates cannot span VPCs).
data_plan = []
def data_slot(card):
    dev = card_used[card]
    card_used[card] += 1
    data_plan.append({"NetworkCardIndex": card, "DeviceIndex": dev})

if n_cards > 1:
    # round-robin across cards (cards >=1 first, card 0 last -- it carries mgmt)
    # so cores > n_cards packs multiple data ENIs per card, up to each card's
    # ENI limit. Cards are a fixed bandwidth domain: two data ENIs on one card
    # share that card's throughput (expected when cores > cards).
    placed = 0
    rr_order = [i for i in sorted(card_max) if i >= 1] + [0]
    while placed < cores:
        progressed = False
        for i in rr_order:
            if placed >= cores: break
            if card_used[i] < card_max[i]:
                if cross_vpc: data_slot(i)
                else: take(i, "interface", f"weka-data (nci{i}/dev{card_used[i]}) - ENA data plane", [sg_ena])
                placed += 1; progressed = True
        if not progressed:
            free = sum(card_max[i] - card_used[i] for i in card_max)
            fail.append(f"core carve total {cores} needs {cores - placed} more data ENI slot(s) but all "
                        f"network cards are full ({free} free) -- reduce DRIVE/COMPUTE/FRONTEND cores or EFA_COUNT")
            break
else:
    if 1 + efa_count + cores > card_max[0]:
        fail.append(f"1 mgmt + {efa_count} EFA + {cores} data ENIs = {1+efa_count+cores} "
                    f"exceeds {itype} ENI limit ({card_max[0]}) -- reduce the core carve")
    else:
        for _ in range(cores):
            if cross_vpc: data_slot(0)
            else: take(0, "interface", f"weka-data (nci0/dev{card_used[0]}) - ENA data plane", [sg_ena])

total_enis = len(enis) + len(data_plan)
if total_enis > total_max:
    fail.append(f"layout needs {total_enis} ENIs but {itype} supports {total_max}")

# ---- subnet capacity --------------------------------------------------------
ips_per_node = sum(1 for e in enis if e["InterfaceType"] == "interface")
if mgmt_subnet_id:
    ips_per_node -= 1   # mgmt IP comes from its own subnet (validated above)
need_ips = ips_per_node * nodes
if subnet["free"] < need_ips:
    warn.append(f"subnet {subnet_id} has {subnet['free']} free IPs; "
                f"{nodes} nodes need {need_ips} ({ips_per_node}/node)")
else:
    print(f"[ok] subnet capacity: {subnet['free']} free IPs >= {need_ips} needed "
          f"({ips_per_node}/node x {nodes} nodes) in {subnet['az']} ({subnet['azId']})")

# ---- results ----------------------------------------------------------------
for w in warn: print(f"[WARN] {w}")
for f in fail: print(f"[FAIL] {f}")
if fail: sys.exit(1)

# default name: avoid the "weka-weka-..." stutter when the cluster name already starts with weka
base = cluster if cluster.lower().startswith("weka") else f"weka-{cluster}"
lt_name = env["LAUNCH_TEMPLATE_NAME"] or f"{base}-{itype.replace('.', '-')}"
# aws-apn-id: WEKA's AWS Partner Network attribution tag -- keep on all resources
APN_TAG = {"Key": "aws-apn-id", "Value": "pc:epkj0ftddjwa38m3oq9umjjlm"}
tags = lambda rt: {"ResourceType": rt, "Tags": [{"Key": "weka-cluster", "Value": cluster}, APN_TAG] +
                   ([{"Key": "Name", "Value": f"{cluster}-node"}] if rt == "instance" else [])}
lt_data = {
    "InstanceType": itype,
    "ImageId": env["AMI_ID"],
    "IamInstanceProfile": {"Arn": env["INSTANCE_PROFILE_ARN"]},
    "MetadataOptions": {"HttpEndpoint": "enabled", "HttpTokens": "required",
                        "HttpPutResponseHopLimit": 2},
    "BlockDeviceMappings": [{"DeviceName": ami["root"],
        "Ebs": {"VolumeSize": int(env["ROOT_VOLUME_GB"]), "VolumeType": env["ROOT_VOLUME_TYPE"],
                "DeleteOnTermination": True, "Encrypted": True}}]
        + ([{"DeviceName": "/dev/sdw",
             "Ebs": {"VolumeSize": (48 + 10 * cores) if env.get("WEKA_OPT_VOLUME_GB") == "auto"
                                   else int(env.get("WEKA_OPT_VOLUME_GB", "0") or 0),
                     "VolumeType": env["ROOT_VOLUME_TYPE"],
                     "DeleteOnTermination": True, "Encrypted": True}}]
           if (env.get("WEKA_OPT_VOLUME_GB") == "auto"
               or int(env.get("WEKA_OPT_VOLUME_GB", "0") or 0) > 0) else []),
    "NetworkInterfaces": enis,
    "TagSpecifications": [tags("instance"), tags("network-interface"), tags("volume")],
}
if env.get("PLACEMENT_GROUP"):
    lt_data["Placement"] = {"GroupName": env["PLACEMENT_GROUP"]}
if env.get("USER_DATA_FILE"):
    import base64
    with open(env["USER_DATA_FILE"], "rb") as _f:
        lt_data["UserData"] = base64.b64encode(_f.read()).decode()
full = {"LaunchTemplateName": lt_name,
        "VersionDescription": f"WEKA converged: 1 mgmt + {efa_count} EFA + {cores} data ENIs "
                              f"(carve {env['DRIVE_CORES']}/{env['COMPUTE_CORES']}/{env['FRONTEND_CORES']}), IMDSv2 hop2",
        "LaunchTemplateData": lt_data}
frag = {k: lt_data[k] for k in ("NetworkInterfaces", "MetadataOptions", "TagSpecifications")}

out = env["OUTPUT_DIR"]
with open(f"{out}/{lt_name}.json", "w") as f: json.dump(full, f, indent=1)
with open(f"{out}/{lt_name}-merge-fragment.json", "w") as f: json.dump(frag, f, indent=1)
if cross_vpc:
    if efa_count > 0:
        print("[WARN] GPU/EFA platform with cross-VPC data: EFA interfaces stay in the "
              "LAUNCH (mgmt) VPC -- EFA cannot be hot-attached or cross VPCs")
    plan = {"cluster": cluster, "subnet_id": subnet_id, "groups": [sg_ena],
            "expected_nodes": nodes, "slots": data_plan}
    with open(f"{out}/data-eni-plan.json", "w") as f: json.dump(plan, f, indent=1)
    print(f"   {out}/data-eni-plan.json  (cross-VPC data ENIs: attach-data-enis.sh runs this after launch)")

print(f"""
== layout for {itype}: {total_enis} ENIs ==
   mgmt      : 1  (card 0 / dev 0)
   efa-only  : {efa_count}
   weka data : {cores}  (= DRIVE {env['DRIVE_CORES']} + COMPUTE {env['COMPUTE_CORES']} + FRONTEND {env['FRONTEND_CORES']})
   IPs/node  : {ips_per_node}

== files written ==
   {out}/{lt_name}.json                 (full template, aws ec2 create-launch-template --cli-input-json)
   {out}/{lt_name}-merge-fragment.json  (graft into an existing launch template as a new version)

== installer values this template was generated for (keep in sync!) ==
   CLUSTER_NAME="{cluster}"
   DRIVE_CORES={env['DRIVE_CORES']} COMPUTE_CORES={env['COMPUTE_CORES']} FRONTEND_CORES={env['FRONTEND_CORES']}
   (AMI {ami['name']}; root device {ami['root']})
""")
PYEOF
[ $? -eq 0 ] || exit 1

case "$CLUSTER_NAME" in
  [Ww]eka*) BASE="$CLUSTER_NAME" ;;
  *)        BASE="weka-${CLUSTER_NAME}" ;;
esac
NAME="${LAUNCH_TEMPLATE_NAME:-${BASE}-$(echo "$INSTANCE_TYPE" | tr '.' '-')}"

if [ "$CREATE_IN_AWS" = "true" ]; then
  echo "== creating launch template ${NAME} in ${AWS_REGION} =="
  if LT_ID=$(aws ec2 create-launch-template --region "$AWS_REGION" \
    --cli-input-json "file://${OUTPUT_DIR}/${NAME}.json" \
    --query 'LaunchTemplate.LaunchTemplateId' --output text 2>/dev/null); then
    echo "   ${LT_ID}"
  else
    # template exists: add the new layout as a version and make it default
    LT_ID=$(aws ec2 describe-launch-templates --region "$AWS_REGION" \
      --launch-template-names "$NAME" --query 'LaunchTemplates[0].LaunchTemplateId' --output text)
    VNUM=$(python3 - "$OUTPUT_DIR/${NAME}.json" <<'PY'
import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["LaunchTemplateData"]))
PY
)
    VER=$(aws ec2 create-launch-template-version --region "$AWS_REGION" \
      --launch-template-id "$LT_ID" --launch-template-data "$VNUM" \
      --query 'LaunchTemplateVersion.VersionNumber' --output text)
    aws ec2 modify-launch-template --region "$AWS_REGION" \
      --launch-template-id "$LT_ID" --default-version "$VER" >/dev/null
    echo "   ${LT_ID} (existing template: layout saved as new default version ${VER})"
  fi
  cat <<NEXT

== next step: launch your nodes ==
   # on-demand / plain ODCR:
   aws ec2 run-instances --region ${AWS_REGION} \\
     --launch-template LaunchTemplateId=${LT_ID} --count ${EXPECTED_NODES}

   # capacity block (add your reservation id):
   aws ec2 run-instances --region ${AWS_REGION} \\
     --launch-template LaunchTemplateId=${LT_ID} --count ${EXPECTED_NODES} \\
     --instance-market-options MarketType=capacity-block \\
     --capacity-reservation-specification "CapacityReservationTarget={CapacityReservationId=cr-CHANGEME}"
NEXT
else
  echo "== not created in AWS (CREATE_IN_AWS=false). To create:"
  echo "   aws ec2 create-launch-template --region ${AWS_REGION} --cli-input-json file://${OUTPUT_DIR}/${NAME}.json"
fi
