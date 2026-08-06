#!/usr/bin/env bash
#
# weka-ssm-install.sh
#
# Converged WEKA cluster installer for AWS multi-NIC instances with local
# NVMe (reference platform: p6-b300.48xlarge). Design:
#   - SSM Run Command fan-out (no SSH required, no inbound access needed)
#   - Tag-based node discovery (tag is stamped by the launch template)
#   - Runtime topology discovery on each node (cores/NUMA, ENA NICs, NVMe)
#
# HOW TO RUN:
#   Run this script ON ONE OF THE CLUSTER NODES (it self-elects: lowest
#   instance-id wins; override with FORCE_ORCHESTRATOR=1). The node payload is
#   embedded below and shipped to all nodes (including this one) via SSM.
#
# IAM (instance profile requirements):
#   All nodes:      AmazonSSMManagedInstanceCore
#   Orchestrator:   ec2:DescribeInstances, ssm:SendCommand,
#                   ssm:ListCommandInvocations, ssm:GetCommandInvocation,
#                   ssm:DescribeInstanceInformation
#   (simplest: put the orchestrator perms on the shared instance role,
#    scoped by tag -- see notes at bottom of the chat / README)
#
set -euo pipefail

###############################################################################
##                        CUSTOMER CONFIGURATION                             ##
##  All environment-specific values live here. Values marked CHANGEME must  ##
##  be set per deployment. Operational override knobs are declared at the   ##
##  bottom of this block -- nothing else is read from the environment.      ##
###############################################################################

CLUSTER_NAME="weka-cluster1"  # CHANGEME: cluster name (must match launch-template tag + IAM condition)

# ---- discovery -------------------------------------------------------------
# Instances are discovered by this tag. It MUST be applied by the launch
# template (TagSpecifications, ResourceType=instance) so nodes are born tagged.
DISCOVERY_TAG_KEY="weka-cluster"
DISCOVERY_TAG_VALUE="${CLUSTER_NAME}"
EXPECTED_NODES=8            # CHANGEME: node count; hard check, set 0 to accept whatever is found. Minimum 6 for 4+2, 8+ for 16+4 -- see runbook

# ---- data protection ---------------------------------------------------------
# CHANGEME: stripe must fit the node count (DATA+PROTECTION <= failure domains = nodes)
# defaults sized for EXPECTED_NODES=8; e.g. 16+4 requires >= 20 nodes
DATA=6
PROTECTION=2
HOT_SPARES=2
JOIN_COUNT=5                # how many mgmt IPs go into --join-ips (min(nodes,5) is fine)

# ---- converged core carve (per node) ----------------------------------------
# Runtime discovery allocates PHYSICAL cores (SMT siblings excluded),
# round-robin across NUMA nodes. Core 0 (+siblings) is always reserved for OS.
# NB: total must be <= data-plane ENI count (14 with the current template)
DRIVE_CORES=4
COMPUTE_CORES=8
FRONTEND_CORES=2

# ---- memory (GiB per core, per role) -----------------------------------------
DRIVE_RAM_PER_CORE_GB=2.5
COMPUTE_RAM_PER_CORE_GB=8
FRONTEND_RAM_PER_CORE_GB=2.5

# ---- management interface -----------------------------------------------------
# Which ENI is the management interface. Must match your launch template.
DRIVES_PER_NODE=0             # 0 = claim ALL instance-store NVMe; N = claim only N (NUMA-interleaved)

# ---- core placement (Slurm coexistence) --------------------------------------
# WEKA_CORE_IDS:     pin WEKA to EXACTLY these cores (cpulist syntax "1-4,49-52";
#                    count must equal the carve total). Empty = auto-select.
# EXCLUDED_CORE_IDS: cores WEKA must NOT use (a core is avoided if ANY of its
#                    hwthreads is listed). Applies to auto-selection only.
# Either way, discovery prints the Slurm CpuSpecList (WEKA cores + SMT
# siblings) to reserve in slurm.conf.
WEKA_CORE_IDS=""
EXCLUDED_CORE_IDS=""
WEKA_OPT_VOLUME_GB=0          # >0: dedicated EBS volume for /opt/weka (must exist in the launch template; generator adds it)

MGMT_NETWORK_CARD=0
MGMT_DEVICE_INDEX=0

# ---- ports ---------------------------------------------------------------------
BASE_PORT_DRIVES=14000
BASE_PORT_COMPUTE=14200
BASE_PORT_FRONTEND=14400

# ---- weka install ----------------------------------------------------------------
# Preferred: WEKA_INSTALL_S3 = s3://bucket/key of the WEKA tarball. Nodes
# download it with their instance role (no presigned URL needed; the bucket
# must be granted in the instance policy's WekaDistroDownload statement).
# Alternative: WEKA_INSTALL_URL = get.weka.io distro URL or a presigned URL.
# Leave both empty only if the AMI already ships the weka agent.
WEKA_INSTALL_S3=""          # CHANGEME (preferred): s3://<bucket>/<weka-tarball>
WEKA_INSTALL_URL=""         # alternative: get.weka.io or presigned URL (expires!)
WEKA_USER="admin"
WEKA_PASS="admin"           # fresh-cluster defaults; rotated automatically at the end (see below)
ROTATE_ADMIN_PASSWORD=true  # generate a strong password, store in Secrets Manager
ADMIN_SECRET_NAME=""        # default: weka/<cluster>/admin

# ---- SSM ----------------------------------------------------------------------------
SSM_TIMEOUT=1200            # seconds to wait per phase
CLOUDWATCH_OUTPUT=true      # also ship command output to CloudWatch Logs
DEBUG=false                 # set true for set -x on nodes

# ---- operational override knobs (settable here or per-run via env) -------------------
FORCE_ORCHESTRATOR="${FORCE_ORCHESTRATOR:-0}"   # 1 = run even if this is not the elected (lowest-id) node

###############################################################################
# weka.conf overlay -- if present, values there OVERRIDE the defaults above.
# Workstation: ./weka.conf (package root). Nodes: /tmp/weka.conf (shipped by
# deploy.sh). See RUNBOOK §4.
for _c in ./weka.conf /tmp/weka.conf; do [ -f "$_c" ] && . "$_c" || true; done
DISCOVERY_TAG_VALUE="${CLUSTER_NAME}"

###############################################################################
##                     NODE PAYLOAD (runs on every node)                     ##
###############################################################################
# Quoted heredoc: nothing here expands on the orchestrator. Config arrives on
# each node via /tmp/weka_node.env (generated below).

NODE_PAYLOAD=$(cat <<'NODE_EOF'
#!/usr/bin/env bash
set -eu
source /tmp/weka_node.env
[ "${DEBUG}" = "true" ] && set -x

PHASE="${1:?usage: weka_node.sh <phase>}"
TOPO_CACHE=/tmp/weka_topology.env

# ---------- IMDSv2 helpers ----------
imds_tok() { curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
             -H "X-aws-ec2-metadata-token-ttl-seconds: 300"; }
imds() { curl -sf -H "X-aws-ec2-metadata-token: $(imds_tok)" \
         "http://169.254.169.254/latest/$1"; }

# ---------- small utils ----------
ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a<<24)+(b<<16)+(c<<8)+d )); }
int2ip() { local i=$1; echo "$(( (i>>24)&255 )).$(( (i>>16)&255 )).$(( (i>>8)&255 )).$(( i&255 ))"; }
expand_cpulist() {  # "0-3,7,9-10" -> "0 1 2 3 7 9 10"
  local out=() part
  IFS=, read -ra parts <<<"$1"
  for part in "${parts[@]}"; do
    if [[ "$part" == *-* ]]; then
      for ((i=${part%-*}; i<=${part#*-}; i++)); do out+=("$i"); done
    else out+=("$part"); fi
  done
  echo "${out[*]}"
}

# ---------- topology discovery (cached) ----------
discover() {
  [ -f "$TOPO_CACHE" ] && { source "$TOPO_CACHE"; return; }

  # --- management NIC: match ENI by device-index + network-card via IMDS ---
  local mac dev card MGMT_MAC=""
  for mac in $(imds meta-data/network/interfaces/macs/ | tr -d '/'); do
    dev=$(imds "meta-data/network/interfaces/macs/${mac}/device-number")
    card=$(imds "meta-data/network/interfaces/macs/${mac}/network-card" 2>/dev/null || echo 0)
    if [ "$dev" = "${MGMT_DEVICE_INDEX}" ] && [ "$card" = "${MGMT_NETWORK_CARD}" ]; then
      MGMT_MAC="$mac"; break
    fi
  done
  [ -n "$MGMT_MAC" ] || { echo "FATAL: no ENI at card=${MGMT_NETWORK_CARD} dev=${MGMT_DEVICE_INDEX}"; exit 1; }
  MGMT_NIC=$(ip -br link | awk -v m="$MGMT_MAC" 'tolower($3)==tolower(m){print $1; exit}')
  MGMT_IP=$(ip -br addr show dev "$MGMT_NIC" | grep -Eo '[0-9.]{7,15}' | head -1)
  [ -n "$MGMT_IP" ] || { echo "FATAL: mgmt NIC $MGMT_NIC has no IPv4"; exit 1; }

  # --- WEKA data-plane NICs: every ENA interface except mgmt ---
  local d n drv nnuma WEKA_NICS_ARR=()
  declare -A NICS_BY_NODE
  NIC_NUMA_KNOWN=1
  for d in /sys/class/net/*; do
    n=$(basename "$d")
    [ "$n" = "lo" ] && continue
    [ -e "$d/device/driver" ] || continue
    drv=$(basename "$(readlink -f "$d/device/driver")")
    [ "$drv" = "ena" ] || continue
    [ "$n" = "$MGMT_NIC" ] && continue
    WEKA_NICS_ARR+=("$n")
    nnuma=$(cat "$d/device/numa_node" 2>/dev/null || echo -1)
    [ "$nnuma" = "-1" ] && NIC_NUMA_KNOWN=0
    NICS_BY_NODE[$nnuma]="${NICS_BY_NODE[$nnuma]:-} $n"
  done
  [ ${#WEKA_NICS_ARR[@]} -ge 3 ] || { echo "FATAL: found only ${#WEKA_NICS_ARR[@]} data-plane ENA NICs"; exit 1; }
  WEKA_NICS="${WEKA_NICS_ARR[*]}"

  # --- data-plane prefix + gateway: derived from a DATA NIC's subnet.
  #     (NOT from the mgmt ENI -- management may live on a separate subnet.) ---
  local dmac cidr base
  dmac=$(cat "/sys/class/net/${WEKA_NICS_ARR[0]}/address")
  cidr=$(imds "meta-data/network/interfaces/macs/${dmac}/subnet-ipv4-cidr-block")
  DP_NETMASK="${cidr#*/}"
  base="${cidr%/*}"
  DP_GATEWAY=$(int2ip $(( $(ip2int "$base") + 1 )))

  # --- ensure every data-plane NIC has an IPv4 (Ubuntu AMIs won't auto-DHCP
  #     secondary ENIs; AL2023 usually will) ---
  local tries
  for n in $WEKA_NICS; do
    ip link set dev "$n" up || true
    tries=0
    until ip -br addr show dev "$n" | grep -Eoq '[0-9.]{7,15}'; do
      dhclient -1 "$n" 2>/dev/null || dhcpcd -4 -1 "$n" 2>/dev/null || true
      tries=$((tries+1)); [ $tries -gt 6 ] && { echo "FATAL: no IPv4 on $n"; exit 1; }
      sleep 5
    done
  done

  # --- physical cores per NUMA node (skip cpu0 + its SMT siblings) ---
  local node cpu sib first reserved
  reserved=" $(cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list \
              | tr ',' ' ' ) "
  declare -A NODE_CORES
  NUMA_NODES=""
  for d in /sys/devices/system/node/node[0-9]*; do
    node=$(basename "$d" | sed 's/node//')
    NUMA_NODES="$NUMA_NODES $node"
    NODE_CORES[$node]=""
    for cpu in $(expand_cpulist "$(cat "$d/cpulist")"); do
      [[ "$reserved" == *" $cpu "* ]] && continue
      sib=$(cat "/sys/devices/system/cpu/cpu${cpu}/topology/thread_siblings_list")
      first=$(expand_cpulist "$sib" | awk '{print $1}')
      [ "$cpu" = "$first" ] || continue
      # customer exclusion: skip the core if ANY of its hwthreads is excluded
      if [ -n "${EXCLUDED_CORE_IDS:-}" ]; then
        local excl_hit=0 s2
        for s2 in $(expand_cpulist "$sib"); do
          [[ " $(expand_cpulist "$EXCLUDED_CORE_IDS") " == *" $s2 "* ]] && excl_hit=1
        done
        [ "$excl_hit" = 1 ] && continue
      fi
      NODE_CORES[$node]="${NODE_CORES[$node]} $cpu"
    done
  done

  # round-robin interleave physical cores across NUMA nodes for balance
  local need=$(( DRIVE_CORES + COMPUTE_CORES + FRONTEND_CORES ))
  local n_numa; n_numa=$(echo $NUMA_NODES | wc -w)
  PAIRED=0
  PINNED=0
  # ---- explicit pin: customer dictates WEKA's cores (WEKA_CORE_IDS) --------
  if [ -n "${WEKA_CORE_IDS:-}" ]; then
    local pin=($(expand_cpulist "$WEKA_CORE_IDS"))
    [ ${#pin[@]} -eq $need ] || { echo "FATAL: WEKA_CORE_IDS lists ${#pin[@]} cores but the carve needs $need (DRIVE+COMPUTE+FRONTEND)"; exit 1; }
    local pc
    for pc in "${pin[@]}"; do
      [ -e "/sys/devices/system/cpu/cpu${pc}" ] || { echo "FATAL: pinned core $pc does not exist"; exit 1; }
      [[ "$reserved" == *" $pc "* ]] && echo "WARN: pinned core $pc shares core 0's hwthreads (OS-reserved)"
    done
    DRIVE_CORE_IDS=$(echo    "${pin[@]:0:$DRIVE_CORES}" | tr ' ' ',')
    COMPUTE_CORE_IDS=$(echo  "${pin[@]:$DRIVE_CORES:$COMPUTE_CORES}" | tr ' ' ',')
    FRONTEND_CORE_IDS=$(echo "${pin[@]:$((DRIVE_CORES+COMPUTE_CORES)):$FRONTEND_CORES}" | tr ' ' ',')
    PINNED=1
    echo "== cores pinned by WEKA_CORE_IDS: ${WEKA_CORE_IDS} =="
    # same-NUMA NIC pairing for pinned cores (greedy) when affinity is exposed
    if [ "$NIC_NUMA_KNOWN" = 1 ] && [ "$n_numa" -gt 1 ] && [ ${#WEKA_NICS_ARR[@]} -eq $need ]; then
      local pin_nics=() cnode nic used=" "
      declare -A nuse
      for pc in "${pin[@]}"; do
        cnode=$(ls -d /sys/devices/system/cpu/cpu${pc}/node[0-9]* 2>/dev/null | head -1)
        cnode=$(basename "${cnode:-node0}" | sed 's/node//')
        nuse[$cnode]=$(( ${nuse[$cnode]:-0} + 1 ))
        nic=$(echo ${NICS_BY_NODE[$cnode]:-} | awk -v i=${nuse[$cnode]} '{print $i}')
        pin_nics+=("${nic:-__TBD__}")
      done
      # fill unmatched slots with any unused NICs
      local i2 j2
      for i2 in $(seq 0 $(( need - 1 ))); do
        [ "${pin_nics[$i2]}" = "__TBD__" ] || { used="${used}${pin_nics[$i2]} "; continue; }
      done
      for i2 in $(seq 0 $(( need - 1 ))); do
        if [ "${pin_nics[$i2]}" = "__TBD__" ]; then
          for j2 in "${WEKA_NICS_ARR[@]}"; do
            [[ "$used" == *" $j2 "* ]] || { pin_nics[$i2]="$j2"; used="${used}${j2} "; break; }
          done
        fi
      done
      DRIVE_NICS=$(echo    "${pin_nics[@]:0:$DRIVE_CORES}")
      COMPUTE_NICS=$(echo  "${pin_nics[@]:$DRIVE_CORES:$COMPUTE_CORES}")
      FRONTEND_NICS=$(echo "${pin_nics[@]:$((DRIVE_CORES+COMPUTE_CORES)):$FRONTEND_CORES}")
      PAIRED=1
      echo "== NUMA-paired NICs for pinned cores =="
      for i2 in $(seq 0 $(( need - 1 ))); do
        echo "   core ${pin[$i2]} <-> ${pin_nics[$i2]}"
      done
    fi
  fi
  # ---- NUMA-aware path: allocate (core, NIC) SAME-NUMA PAIRS, round-robin
  # across nodes. Requires exposed NIC affinity, >1 NUMA node, and a 1:1
  # core:data-NIC layout (what the generator produces). Ordering matters:
  # within a container WEKA maps the Nth --net to the Nth core, so paired
  # ordering here yields NUMA-local DPDK polling.
  if [ "$PINNED" != 1 ] && [ "$NIC_NUMA_KNOWN" = 1 ] && [ "$n_numa" -gt 1 ] && [ ${#WEKA_NICS_ARR[@]} -eq $need ]; then
    local pool_cores=() pool_nics=() remaining=1 core nic
    declare -A cidx nidx
    for node in $NUMA_NODES; do cidx[$node]=1; nidx[$node]=1; done
    while [ $remaining -eq 1 ]; do
      remaining=0
      for node in $NUMA_NODES; do
        set -- ${NODE_CORES[$node]};        local ctot=$#
        set -- ${NICS_BY_NODE[$node]:-};    local ntot=$#
        if [ ${cidx[$node]} -le $ctot ] && [ ${nidx[$node]} -le $ntot ]; then
          core=$(echo ${NODE_CORES[$node]}     | awk -v i=${cidx[$node]} '{print $i}')
          nic=$(echo  ${NICS_BY_NODE[$node]}   | awk -v i=${nidx[$node]} '{print $i}')
          pool_cores+=("$core"); pool_nics+=("$nic")
          cidx[$node]=$(( ${cidx[$node]} + 1 )); nidx[$node]=$(( ${nidx[$node]} + 1 ))
          remaining=1
        fi
      done
    done
    if [ ${#pool_cores[@]} -ge $need ]; then
      DRIVE_CORE_IDS=$(echo    "${pool_cores[@]:0:$DRIVE_CORES}" | tr ' ' ',')
      COMPUTE_CORE_IDS=$(echo  "${pool_cores[@]:$DRIVE_CORES:$COMPUTE_CORES}" | tr ' ' ',')
      FRONTEND_CORE_IDS=$(echo "${pool_cores[@]:$((DRIVE_CORES+COMPUTE_CORES)):$FRONTEND_CORES}" | tr ' ' ',')
      DRIVE_NICS=$(echo    "${pool_nics[@]:0:$DRIVE_CORES}")
      COMPUTE_NICS=$(echo  "${pool_nics[@]:$DRIVE_CORES:$COMPUTE_CORES}")
      FRONTEND_NICS=$(echo "${pool_nics[@]:$((DRIVE_CORES+COMPUTE_CORES)):$FRONTEND_CORES}")
      PAIRED=1
      echo "== NUMA-paired core<->NIC assignment =="
      local i
      for i in $(seq 0 $(( need - 1 ))); do
        n="${pool_nics[$i]}"
        echo "   core ${pool_cores[$i]} <-> ${n} (numa $(cat /sys/class/net/$n/device/numa_node 2>/dev/null))"
      done
    fi
  fi

  # ---- fallback: balanced round-robin interleave (affinity hidden, single
  # NUMA node, or non-1:1 core:NIC layout)
  if [ "$PINNED" != 1 ] && [ "$PAIRED" != 1 ]; then
    local remaining=1 pool=()
    declare -A idx
    for node in $NUMA_NODES; do idx[$node]=1; done
    while [ $remaining -eq 1 ]; do
      remaining=0
      for node in $NUMA_NODES; do
        set -- ${NODE_CORES[$node]}
        if [ ${idx[$node]} -le $# ]; then
          eval "pool+=(\${${idx[$node]}})"
          idx[$node]=$(( ${idx[$node]} + 1 ))
          remaining=1
        fi
      done
    done
    [ ${#pool[@]} -ge $need ] || { echo "FATAL: need $need physical cores, have ${#pool[@]}"; exit 1; }
    DRIVE_CORE_IDS=$(echo    "${pool[@]:0:$DRIVE_CORES}" | tr ' ' ',')
    COMPUTE_CORE_IDS=$(echo  "${pool[@]:$DRIVE_CORES:$COMPUTE_CORES}" | tr ' ' ',')
    FRONTEND_CORE_IDS=$(echo "${pool[@]:$((DRIVE_CORES+COMPUTE_CORES)):$FRONTEND_CORES}" | tr ' ' ',')
  fi

  # --- instance-store NVMe (exclude EBS) ---
  # ---- Slurm helper: every hwthread WEKA occupies (cores + SMT siblings) ----
  local ac sspec=""
  for ac in $(echo "$DRIVE_CORE_IDS,$COMPUTE_CORE_IDS,$FRONTEND_CORE_IDS" | tr ',' ' '); do
    sspec="$sspec $(expand_cpulist "$(cat /sys/devices/system/cpu/cpu${ac}/topology/thread_siblings_list)")"
  done
  WEKA_CPUSPEC=$(echo $sspec | tr ' ' '\n' | sort -un | paste -sd, -)
  echo "== Slurm CpuSpecList (WEKA cores + SMT siblings): ${WEKA_CPUSPEC} =="

  # enumerate BLOCK devices, not controllers: the controller index and the
  # namespace name can diverge (e.g. NVMe native multipath on RHEL-family
  # kernels), so "/sys/class/nvme/nvme5" + "n1" may name someone ELSE's disk.
  # Reading the model through the block device's own backing link claims
  # exactly the device we hand to WEKA.
  local b model devs=() pairs=() nn
  for b in /sys/block/nvme*n1; do
    [ -e "$b/device/model" ] || continue
    model=$(cat "$b/device/model")
    if echo "$model" | grep -qi "Instance Storage"; then
      part=$(basename "$b")
      # skip devices the OS already claims: LVM/RAID holders, partitions,
      # mounted filesystems, or a foreign on-disk signature (e.g. an image
      # that assembles local disks into scratch storage). WEKA-formatted
      # drives report no blkid TYPE, so reinstall reclaim still works.
      if [ -n "$(ls -A "$b/holders" 2>/dev/null)" ] \
         || ls -d "$b/${part}p"* >/dev/null 2>&1 \
         || grep -q "^/dev/${part}[ p]" /proc/mounts \
         || [ -n "$(blkid -o value -s TYPE "/dev/${part}" 2>/dev/null)" ]; then
        echo "   skipping /dev/${part} (in use: holder/partition/mount/signature)"
        continue
      fi
      nn=$(cat "$b/device/device/numa_node" 2>/dev/null \
           || cat "$b/device/numa_node" 2>/dev/null || echo 0)
      [ "$nn" = "-1" ] && nn=0
      devs+=("/dev/$(basename "$b")")
      pairs+=("$nn /dev/$(basename "$b")")
    fi
  done
  [ ${#devs[@]} -gt 0 ] || { echo "FATAL: no CLAIMABLE instance-store NVMe found (all missing or skipped as in-use -- see lines above)"; exit 1; }
  # optional cap: DRIVES_PER_NODE>0 claims only N drives, selected round-robin
  # across NUMA nodes so a partial claim stays balanced
  if [ "${DRIVES_PER_NODE:-0}" -gt 0 ] 2>/dev/null && [ ${#devs[@]} -gt "${DRIVES_PER_NODE}" ]; then
    WEKA_DRIVES=$(printf '%s\n' "${pairs[@]}" | sort -k1,1n -k2,2 \
      | awk '{print ++cnt[$1], $0}' | sort -k1,1n -k2,2n \
      | head -n "${DRIVES_PER_NODE}" | awk '{print $3}' | tr '\n' ' ')
    WEKA_DRIVES="${WEKA_DRIVES% }"
    echo "claiming ${DRIVES_PER_NODE} of ${#devs[@]} instance-store drives (NUMA-interleaved): ${WEKA_DRIVES}"
  else
    WEKA_DRIVES="${devs[*]}"
  fi

  # --- split data-plane NICs across roles, proportional to cores, min 1 each ---
  if [ "$PAIRED" != 1 ]; then
    local total_nics=${#WEKA_NICS_ARR[@]} total_cores=$need
    local n_d n_c n_f
    n_d=$(( total_nics * DRIVE_CORES    / total_cores )); [ $n_d -lt 1 ] && n_d=1
    n_f=$(( total_nics * FRONTEND_CORES / total_cores )); [ $n_f -lt 1 ] && n_f=1
    n_c=$(( total_nics - n_d - n_f ));                    [ $n_c -lt 1 ] && n_c=1
    DRIVE_NICS=$(echo    "${WEKA_NICS_ARR[@]:0:$n_d}")
    COMPUTE_NICS=$(echo  "${WEKA_NICS_ARR[@]:$n_d:$n_c}")
    FRONTEND_NICS=$(echo "${WEKA_NICS_ARR[@]:$((n_d+n_c)):$n_f}")
  fi

  # failure domain: instance-id (stable, unique)
  FAILURE_DOMAIN=$(imds meta-data/instance-id | tr -d '"' | sed 's/^i-//' | cut -c1-15)

  cat > "$TOPO_CACHE" <<CACHE
MGMT_NIC="$MGMT_NIC"
MGMT_IP="$MGMT_IP"
DP_NETMASK="$DP_NETMASK"
DP_GATEWAY="$DP_GATEWAY"
WEKA_NICS="$WEKA_NICS"
DRIVE_CORE_IDS="$DRIVE_CORE_IDS"
COMPUTE_CORE_IDS="$COMPUTE_CORE_IDS"
FRONTEND_CORE_IDS="$FRONTEND_CORE_IDS"
WEKA_DRIVES="$WEKA_DRIVES"
DRIVE_NICS="$DRIVE_NICS"
COMPUTE_NICS="$COMPUTE_NICS"
FRONTEND_NICS="$FRONTEND_NICS"
FAILURE_DOMAIN="$FAILURE_DOMAIN"
WEKA_CPUSPEC="$WEKA_CPUSPEC"
CACHE
  echo "== topology =="; cat "$TOPO_CACHE"
}

net_args() {  # $1 = space-separated nic list
  local nic ip args=""
  for nic in $1; do
    ip=$(ip -br addr show dev "$nic" | grep -Eo '[0-9.]{7,15}' | head -1)
    args+=" --net ${nic}/${ip}/${DP_NETMASK}/${DP_GATEWAY}"
  done
  echo "$args"
}

mem_gb() { awk -v c="$1" -v r="$2" 'BEGIN{printf "%g", c*r}'; }

setup_container() {  # name, role_flag, base_port, cores_n, core_ids, mem, nics, join(0/1)
  local name=$1 flag=$2 port=$3 ncores=$4 ids=$5 mem=$6 nics=$7 join=$8
  local cmd="weka local setup container --name $name $flag --base-port $port"
  cmd+=" --cores $ncores --core-ids $ids --memory ${mem}GB"
  cmd+=" --failure-domain $FAILURE_DOMAIN"
  [ "$join" = "1" ] && cmd+=" --join-ips ${JOIN_IPS}"
  cmd+="$(net_args "$nics")"
  cmd+=" --management-ips $MGMT_IP"
  echo "+ $cmd"
  if ! eval "$cmd"; then
    # transient create failures happen (e.g. loop-device busy during squashfs
    # prepare) -- clean the partial container and retry once
    echo "setup of $name failed -- removing partial container and retrying once"
    weka local rm -f "$name" 2>/dev/null || true
    sleep 10
    eval "$cmd"
  fi
}

case "$PHASE" in
  install)
    # build deps for weka driver compilation: kernel headers + the exact gcc
    # the running kernel was built with (e.g. jammy HWE kernel wants gcc-12,
    # which plain Ubuntu AMIs do not ship). Mirrors are S3-backed on EC2.
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -q >/dev/null 2>&1 || true
      KGCC=$(grep -oE 'gcc-[0-9]+' /proc/version | head -1)
      apt-get install -yq make gcc ${KGCC:-} jq awscli "linux-headers-$(uname -r)" >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -yq make gcc jq awscli "kernel-devel-$(uname -r)" >/dev/null 2>&1 \
        || dnf install -yq make gcc jq awscli kernel-devel >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -yq make gcc jq awscli "kernel-devel-$(uname -r)" >/dev/null 2>&1 || true
    fi
    # EL point-release drift (Rocky/Alma): live repos roll past the AMI's
    # release and drop kernel-devel for its RUNNING kernel; the WEKA driver
    # build needs the exact match -- fetch it from the distro vault instead
    if command -v rpm >/dev/null 2>&1 && ! rpm -q "kernel-devel-$(uname -r)" >/dev/null 2>&1; then
      . /etc/os-release 2>/dev/null || true
      PR=$(uname -r | grep -oE 'el[0-9]+_[0-9]+' | sed 's/el//; s/_/./')
      VURL=""
      case "${ID:-}" in
        rocky)     VURL="https://dl.rockylinux.org/vault/rocky/${PR}/AppStream/$(uname -m)/os/Packages/k/kernel-devel-$(uname -r).rpm" ;;
        almalinux) VURL="https://repo.almalinux.org/vault/${PR}/AppStream/$(uname -m)/os/Packages/kernel-devel-$(uname -r).rpm" ;;
      esac
      [ -n "$VURL" ] && { dnf install -yq "$VURL" >/dev/null 2>&1 || yum install -yq "$VURL" >/dev/null 2>&1 || true; }
    fi
    # RHEL-family distros (Rocky/Alma/RHEL) carry awscli only in EPEL -- fall
    # back to the official AWS CLI v2 bundle when the package manager has none
    if ! command -v aws >/dev/null 2>&1; then
      command -v unzip >/dev/null 2>&1 || dnf install -yq unzip >/dev/null 2>&1 || yum install -yq unzip >/dev/null 2>&1 || apt-get install -yq unzip >/dev/null 2>&1 || true
      curl -sf "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip \
        && unzip -qo /tmp/awscliv2.zip -d /tmp/awscliv2 \
        && /tmp/awscliv2/aws/install >/dev/null 2>&1 || true
      rm -rf /tmp/awscliv2 /tmp/awscliv2.zip
    fi
    command -v jq >/dev/null 2>&1 || { echo "FATAL: jq unavailable and could not be installed"; exit 1; }
    # dedicated /opt/weka volume: find the unused EBS data volume, format,
    # mount, persist -- BEFORE the weka agent installs into /opt/weka
    if { [ "${WEKA_OPT_VOLUME_GB:-0}" = "auto" ] || [ "${WEKA_OPT_VOLUME_GB:-0}" -gt 0 ] 2>/dev/null; } && ! mountpoint -q /opt/weka 2>/dev/null; then
      WDEV=""
      for D2 in /dev/nvme*n1; do
        [ -b "$D2" ] || continue
        grep -qi "Elastic Block Store" "/sys/class/nvme/$(basename "${D2%n1}")/model" 2>/dev/null || continue
        [ -n "$(lsblk -no MOUNTPOINT "$D2" 2>/dev/null | tr -d '[:space:]')" ] && continue
        [ "$(lsblk -n "$D2" | wc -l)" -gt 1 ] && continue
        blkid "$D2" >/dev/null 2>&1 && continue
        WDEV="$D2"; break
      done
      if [ -n "$WDEV" ]; then
        command -v mkfs.xfs >/dev/null 2>&1 || { command -v apt-get >/dev/null 2>&1 && apt-get install -yq xfsprogs >/dev/null 2>&1 || yum install -yq xfsprogs >/dev/null 2>&1 || dnf install -yq xfsprogs >/dev/null 2>&1 || true; }
        mkfs.xfs -q "$WDEV"
        mkdir -p /opt/weka
        mount "$WDEV" /opt/weka
        echo "UUID=$(blkid -s UUID -o value "$WDEV") /opt/weka xfs defaults,nofail 0 2" >> /etc/fstab
        echo "dedicated /opt/weka volume mounted: $WDEV ($(lsblk -dno SIZE "$WDEV"))"
      else
        echo "WARN: WEKA_OPT_VOLUME_GB=${WEKA_OPT_VOLUME_GB} configured but no unused EBS volume found -- /opt/weka stays on the root filesystem"
      fi
    fi
    if ! command -v weka >/dev/null 2>&1; then
      cd /tmp
      if [ -n "${WEKA_INSTALL_S3}" ]; then
        command -v aws >/dev/null 2>&1 || { echo "FATAL: aws CLI needed for WEKA_INSTALL_S3 and could not be installed"; exit 1; }
        echo "downloading ${WEKA_INSTALL_S3} via instance role"
        aws s3 cp "${WEKA_INSTALL_S3}" weka_dist --no-progress \
          || { echo "FATAL: s3 cp failed -- is the bucket granted in the instance policy (WekaDistroDownload)?"; exit 1; }
      elif [ -n "${WEKA_INSTALL_URL}" ]; then
        curl -fsSL "${WEKA_INSTALL_URL}" -o weka_dist
      else
        echo "FATAL: weka agent not present and no install source configured (WEKA_INSTALL_S3 / WEKA_INSTALL_URL)"; exit 1
      fi
      if file weka_dist | grep -qi 'shell script\|ascii text'; then sh weka_dist
      else mkdir -p weka_dist_x && tar xf weka_dist -C weka_dist_x --strip-components=1 \
           && cd weka_dist_x && ./install.sh; fi
    else
      echo "weka agent present, skipping install"
    fi
    command -v weka >/dev/null 2>&1 || { echo "FATAL: weka CLI not installed"; exit 1; }
    ;;
  cleanup)
    weka local ps 2>/dev/null | grep -qi drives0 && { echo "FATAL: cluster containers already present -- run teardown first"; exit 1; }
    weka local stop -f  || true
    weka local rm --all -f || true
    rm -f "$TOPO_CACHE"
    ;;
  drives)
    discover
    setup_container drives0 --only-drives-cores "$BASE_PORT_DRIVES" \
      "$DRIVE_CORES" "$DRIVE_CORE_IDS" "$(mem_gb "$DRIVE_CORES" "$DRIVE_RAM_PER_CORE_GB")" \
      "$DRIVE_NICS" 0
    ;;
  compute)
    discover
    setup_container compute0 --only-compute-cores "$BASE_PORT_COMPUTE" \
      "$COMPUTE_CORES" "$COMPUTE_CORE_IDS" "$(mem_gb "$COMPUTE_CORES" "$COMPUTE_RAM_PER_CORE_GB")" \
      "$COMPUTE_NICS" 1
    ;;
  frontend)
    discover
    setup_container frontend0 --only-frontend-cores "$BASE_PORT_FRONTEND" \
      "$FRONTEND_CORES" "$FRONTEND_CORE_IDS" "$(mem_gb "$FRONTEND_CORES" "$FRONTEND_RAM_PER_CORE_GB")" \
      "$FRONTEND_NICS" 1
    ;;
  adddrives)
    discover
    weka user login "$WEKA_USER" "$WEKA_PASS"
    # JSON output (-J): stable named fields instead of CLI column positions
    cid=$(weka cluster container -J | jq -r --arg ip "$MGMT_IP" \
          '.[] | select(.container_name=="drives0" and (.ips | index($ip))) | .host_id' \
          | grep -oE '[0-9]+' | head -1)
    [ -n "$cid" ] || { echo "FATAL: could not resolve drives0 container id for $MGMT_IP"; exit 1; }
    # per-drive adds, tolerant of a prior interrupted attempt that claimed a
    # device locally without registering it ("Device is already in use")
    rc=0
    for d in $WEKA_DRIVES; do
      if out=$(weka cluster drive add "$cid" "$d" --force 2>&1); then
        echo "added $d"
      elif echo "$out" | grep -qi 'already in use\|already exist'; then
        echo "tolerated $d: already claimed (prior attempt)"
      else
        echo "ERROR adding $d: $out"; rc=1
      fi
    done
    [ $rc -eq 0 ] || exit 1
    ;;
  *)
    echo "unknown phase: $PHASE"; exit 1;;
esac
NODE_EOF
)

###############################################################################
##                            ORCHESTRATOR LOGIC                             ##
###############################################################################

log() { echo -e "\n=== $* ==="; }

# ---- ensure AWS CLI (plain distro AMIs ship without it; distro mirrors are
#      S3-backed on EC2, so this works even on subnets with no internet route) ----
if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI missing -- installing"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q >/dev/null 2>&1 || true
    apt-get install -yq awscli >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then dnf install -yq awscli >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then yum install -yq awscli >/dev/null 2>&1 || true
  fi
  if ! command -v aws >/dev/null 2>&1; then
    # RHEL-family base repos lack awscli (EPEL-only) -- official v2 bundle
    command -v unzip >/dev/null 2>&1 || dnf install -yq unzip >/dev/null 2>&1 || yum install -yq unzip >/dev/null 2>&1 || apt-get install -yq unzip >/dev/null 2>&1 || true
    curl -sf "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip \
      && unzip -qo /tmp/awscliv2.zip -d /tmp/awscliv2 \
      && /tmp/awscliv2/aws/install >/dev/null 2>&1 || true
    rm -rf /tmp/awscliv2 /tmp/awscliv2.zip
  fi
  command -v aws >/dev/null 2>&1 || { echo "FATAL: aws CLI unavailable and could not be installed"; exit 1; }
fi

# ---- self identity ----
IMDS_TOK=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
           -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
imds() { curl -sf -H "X-aws-ec2-metadata-token: ${IMDS_TOK}" \
         "http://169.254.169.254/latest/$1"; }
SELF_ID=$(imds meta-data/instance-id)
REGION=$(imds meta-data/placement/region)
export AWS_DEFAULT_REGION="$REGION"

# ---- discover cluster members by tag ----
log "Discovering instances tagged ${DISCOVERY_TAG_KEY}=${DISCOVERY_TAG_VALUE} in ${REGION}"
mapfile -t NODES < <(aws ec2 describe-instances \
  --filters "Name=tag:${DISCOVERY_TAG_KEY},Values=${DISCOVERY_TAG_VALUE}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress,PrivateDnsName]' \
  --output text | sort)

NODE_IDS=(); NODE_IPS=(); NODE_NAMES=()
for line in "${NODES[@]}"; do
  NODE_IDS+=( "$(awk '{print $1}' <<<"$line")" )
  NODE_IPS+=( "$(awk '{print $2}' <<<"$line")" )
  NODE_NAMES+=( "$(awk '{print $3}' <<<"$line" | cut -d. -f1)" )
done
N=${#NODE_IDS[@]}
log "Found ${N} nodes: ${NODE_IDS[*]}"
if [ "$EXPECTED_NODES" -gt 0 ] && [ "$N" -ne "$EXPECTED_NODES" ]; then
  echo "FATAL: expected ${EXPECTED_NODES} nodes, found ${N}"; exit 1
fi

# ---- self-election: lowest instance-id runs the show ----
if [ "${NODE_IDS[0]}" != "$SELF_ID" ] && [ "${FORCE_ORCHESTRATOR:-0}" != "1" ]; then
  echo "FATAL: I am ${SELF_ID}; elected orchestrator is ${NODE_IDS[0]}."
  echo "Run this script there, or re-run with FORCE_ORCHESTRATOR=1."
  exit 1
fi

HOST_IPS=$(IFS=,; echo "${NODE_IPS[*]}")
HOST_NAMES="${NODE_NAMES[*]}"
JOIN_IPS=$(printf '%s\n' "${NODE_IPS[@]}" | head -n "$JOIN_COUNT" | paste -sd, -)

# ---- wait for SSM agents ----
log "Waiting for all ${N} nodes to be SSM-online"
deadline=$(( $(date +%s) + 600 ))
while :; do
  online=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$(IFS=,; echo "${NODE_IDS[*]}")" \
    --query 'length(InstanceInformationList[?PingStatus==`Online`])' --output text)
  [ "$online" = "$N" ] && break
  [ $(date +%s) -gt $deadline ] && { echo "FATAL: only ${online}/${N} SSM-online"; exit 1; }
  echo "  ${online}/${N} online..."; sleep 10
done

# ---- build node env + payload (base64, no quoting hazards over SSM) ----
# values are quoted: URLs (presigned S3 / get.weka.io) contain & and ?
NODE_ENV=$(cat <<ENV_EOF
DEBUG="${DEBUG}"
DRIVE_CORES="${DRIVE_CORES}"
COMPUTE_CORES="${COMPUTE_CORES}"
FRONTEND_CORES="${FRONTEND_CORES}"
DRIVE_RAM_PER_CORE_GB="${DRIVE_RAM_PER_CORE_GB}"
COMPUTE_RAM_PER_CORE_GB="${COMPUTE_RAM_PER_CORE_GB}"
FRONTEND_RAM_PER_CORE_GB="${FRONTEND_RAM_PER_CORE_GB}"
DRIVES_PER_NODE="${DRIVES_PER_NODE}"
WEKA_CORE_IDS="${WEKA_CORE_IDS}"
EXCLUDED_CORE_IDS="${EXCLUDED_CORE_IDS}"
WEKA_OPT_VOLUME_GB="${WEKA_OPT_VOLUME_GB}"
MGMT_NETWORK_CARD="${MGMT_NETWORK_CARD}"
MGMT_DEVICE_INDEX="${MGMT_DEVICE_INDEX}"
BASE_PORT_DRIVES="${BASE_PORT_DRIVES}"
BASE_PORT_COMPUTE="${BASE_PORT_COMPUTE}"
BASE_PORT_FRONTEND="${BASE_PORT_FRONTEND}"
JOIN_IPS="${JOIN_IPS}"
WEKA_INSTALL_S3="${WEKA_INSTALL_S3}"
WEKA_INSTALL_URL="${WEKA_INSTALL_URL}"
WEKA_USER="${WEKA_USER}"
WEKA_PASS="${WEKA_PASS}"
ENV_EOF
)
ENV_B64=$(base64 -w0 <<<"$NODE_ENV")
PAYLOAD_B64=$(base64 -w0 <<<"$NODE_PAYLOAD")

CW_ARGS=()
[ "$CLOUDWATCH_OUTPUT" = "true" ] && \
  CW_ARGS=(--cloud-watch-output-config "CloudWatchOutputEnabled=true,CloudWatchLogGroupName=/weka/install/${CLUSTER_NAME}")

# ---- SSM fan-out helper: run one phase on a set of instance ids ----
run_phase() {  # $1=phase  $2..=instance ids
  local phase=$1; shift
  local ids=("$@")
  log "Phase '${phase}' on ${#ids[@]} node(s)"
  local cmd="echo ${ENV_B64} | base64 -d > /tmp/weka_node.env && echo ${PAYLOAD_B64} | base64 -d > /tmp/weka_node.sh && sudo -E bash /tmp/weka_node.sh ${phase}"
  local cmd_id
  cmd_id=$(aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --instance-ids "${ids[@]}" \
    --comment "weka ${CLUSTER_NAME} phase ${phase}" \
    --timeout-seconds "$SSM_TIMEOUT" \
    --parameters "commands=[\"${cmd}\"],executionTimeout=[\"${SSM_TIMEOUT}\"]" \
    "${CW_ARGS[@]}" \
    --query 'Command.CommandId' --output text)

  local deadline=$(( $(date +%s) + SSM_TIMEOUT + 60 ))
  while :; do
    mapfile -t st < <(aws ssm list-command-invocations --command-id "$cmd_id" \
      --query 'CommandInvocations[].[InstanceId,Status]' --output text)
    local pending=0 failed=""
    for line in "${st[@]}"; do
      case "$(awk '{print $2}' <<<"$line")" in
        Success) ;;
        Pending|InProgress|Delayed) pending=1 ;;
        *) failed+=" $(awk '{print $1}' <<<"$line")" ;;
      esac
    done
    [ ${#st[@]} -lt ${#ids[@]} ] && pending=1
    if [ -n "$failed" ]; then
      echo "FATAL: phase '${phase}' failed on:${failed}"
      for iid in $failed; do
        echo "--- ${iid} stdout/stderr tail ---"
        aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$iid" \
          --query '[StandardOutputContent,StandardErrorContent]' --output text | tail -40
      done
      exit 1
    fi
    [ $pending -eq 0 ] && break
    [ $(date +%s) -gt $deadline ] && { echo "FATAL: phase '${phase}' timed out"; exit 1; }
    sleep 10
  done
  log "Phase '${phase}' complete"
}

###############################################################################
##                                RUN                                        ##
###############################################################################

# stripe must fit the failure domains (= nodes) BEFORE any node work: WEKA
# accepts a wider stripe at cluster-update time and comes up permanently
# PARTIALLY_PROTECTED -- refuse instead of building a degraded cluster
N=${#NODE_IDS[@]}
if [ $(( DATA + PROTECTION )) -gt "$N" ]; then
  log "FATAL: stripe ${DATA}+${PROTECTION} needs $(( DATA + PROTECTION )) failure domains but only ${N} nodes exist -- set DATA/PROTECTION in weka.conf to fit (e.g. DATA=$(( N - PROTECTION )) PROTECTION=${PROTECTION})"
  exit 1
fi

# always run install: it also lays down build deps (headers/gcc/jq/awscli);
# the phase itself skips the weka download when the agent is already present
run_phase install "${NODE_IDS[@]}"

run_phase cleanup "${NODE_IDS[@]}"
run_phase drives  "${NODE_IDS[@]}"

log "Creating cluster (local, on orchestrator)"
sudo weka cluster create ${HOST_NAMES} --host-ips="${HOST_IPS}"
sleep 30

log "Protection: ${DATA}+${PROTECTION}, hot spares: ${HOT_SPARES}"
sudo weka user login "$WEKA_USER" "$WEKA_PASS" || true
sudo weka cluster update --data-drives "${DATA}" --parity-drives "${PROTECTION}" --cluster-name "${CLUSTER_NAME}"
sudo weka cluster hot-spare "${HOT_SPARES}"

run_phase compute   "${NODE_IDS[@]}"
run_phase frontend  "${NODE_IDS[@]}"
run_phase adddrives "${NODE_IDS[@]}"

log "Starting IO"
sudo weka cluster start-io
sleep 10
sudo weka status

# ---- record deployment baseline (source of truth for day-2 scale-in floor) ----
aws ssm put-parameter --name "/weka/${CLUSTER_NAME}/baseline" --type String --overwrite \
  --value "{\"original_nodes\":${N},\"data\":${DATA},\"parity\":${PROTECTION},\"hot_spares\":${HOT_SPARES}}" \
  >/dev/null 2>&1 && log "Baseline recorded: /weka/${CLUSTER_NAME}/baseline (original_nodes=${N})" \
  || log "WARN: could not write baseline SSM parameter (day-2 scale-in will need --original-size)"

# ---- rotate admin password + store in Secrets Manager ----
# Order matters: store the new password FIRST, rotate second -- so the secret
# can never end up holding a password that was lost. On rotation failure the
# secret is restored to the old value.
if [ "${ROTATE_ADMIN_PASSWORD}" = "true" ]; then
  SECRET_NAME="${ADMIN_SECRET_NAME:-weka/${CLUSTER_NAME}/admin}"
  NEW_PASS="Wk$(openssl rand -hex 12)9x"   # upper+lower+digits, 28 chars, meets weka policy
  store_secret() {
    aws secretsmanager put-secret-value --secret-id "$SECRET_NAME" \
      --secret-string "{\"username\":\"${WEKA_USER}\",\"password\":\"$1\"}" >/dev/null 2>&1 \
    || aws secretsmanager create-secret --name "$SECRET_NAME" \
      --secret-string "{\"username\":\"${WEKA_USER}\",\"password\":\"$1\"}" >/dev/null 2>&1
  }
  if store_secret "$NEW_PASS"; then
    if sudo weka user passwd "$NEW_PASS" --current-password "$WEKA_PASS" >/dev/null; then
      log "Admin password rotated; credentials stored in Secrets Manager: ${SECRET_NAME}"
    else
      store_secret "$WEKA_PASS" || true
      log "WARN: password rotation FAILED -- secret restored to previous value; rotate manually"
    fi
  else
    log "WARN: cannot write to Secrets Manager (${SECRET_NAME}) -- skipping rotation; rotate manually: weka user passwd"
  fi
else
  log "Password rotation disabled -- rotate manually: weka user passwd"
fi

log "Cluster is up. Next steps (run from your workstation)"
if [ "${ROTATE_ADMIN_PASSWORD}" = "true" ]; then
  cat <<NEXT

  # 1. retrieve the admin credentials:
  aws secretsmanager get-secret-value --region ${REGION} \\
    --secret-id ${SECRET_NAME:-weka/${CLUSTER_NAME}/admin} \\
    --query SecretString --output text

NEXT
else
  echo "  # 1. credentials: ${WEKA_USER} with the password you configured (rotation was disabled)"
fi
cat <<NEXT
  # 2. open the WEKA UI through an SSM port-forward to this backend (${SELF_ID}):
  aws ssm start-session --region ${REGION} --target ${SELF_ID} \\
    --document-name AWS-StartPortForwardingSession \\
    --parameters '{"portNumber":["14000"],"localPortNumber":["14000"]}'

  # then browse to:  https://localhost:14000

  # 3. day-2 operations (scale-out / scale-in / replace / status):
  #    see the runbook -- ./deploy.sh day2 status
NEXT
# Slurm coexistence: reserve WEKA's hwthreads so the scheduler never places
# jobs on them (identical on every node of a homogeneous fleet)
if [ -f /tmp/weka_topology.env ]; then
  WEKA_CPUSPEC=$(grep '^WEKA_CPUSPEC=' /tmp/weka_topology.env | cut -d'"' -f2)
  [ -n "$WEKA_CPUSPEC" ] && cat <<SLURM

  # 4. running Slurm on these nodes? Reserve WEKA's hwthreads in slurm.conf:
  #      CpuSpecList=${WEKA_CPUSPEC}
  #    (and size MemSpecLimit for the WEKA container memory you configured)
SLURM
fi

log "Done."
