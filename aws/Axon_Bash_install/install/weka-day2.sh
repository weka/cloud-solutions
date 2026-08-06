#!/usr/bin/env bash
#
# weka-day2.sh
#
# Day-2 operations for clusters deployed by weka-ssm-install.sh:
#   scale-out              adopt all tagged-but-not-member running instances
#   scale-in <iid> [...]   graceful serialized removal of member nodes
#   replace <failed-iid>   swap a failed node (add-first by default)
#   status                 membership vs tags, protection, baseline
#
# HOW TO RUN:
#   On any healthy CLUSTER MEMBER node (ships payloads via SSM like day-0).
#   USER CONFIGURATION below must match the day-0 installer's values.
#
# SCALE-IN FLOOR: WEKA does not support shrinking below the ORIGINAL cluster
# size. The floor comes from the SSM parameter /weka/<cluster>/baseline
# (written by day-0 install); override with ORIGINAL_SIZE=<n> env var only if
# the parameter is missing. The floor never moves, regardless of later
# scale-out/in history.
#
set -euo pipefail

###############################################################################
##            CUSTOMER CONFIGURATION (must match day-0 installer)            ##
##  All environment-specific values live here. Operational override knobs   ##
##  are declared at the bottom of this block.                                ##
###############################################################################

CLUSTER_NAME="weka-cluster1"  # CHANGEME: must match day-0 / launch template tag / IAM condition

DISCOVERY_TAG_KEY="weka-cluster"
DISCOVERY_TAG_VALUE="${CLUSTER_NAME}"

# core carve / memory for NEW nodes (scale-out, replace) -- same as day-0
DRIVE_CORES=4
COMPUTE_CORES=8
FRONTEND_CORES=2
DRIVE_RAM_PER_CORE_GB=2.5
COMPUTE_RAM_PER_CORE_GB=8
FRONTEND_RAM_PER_CORE_GB=2.5

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

BASE_PORT_DRIVES=14000
BASE_PORT_COMPUTE=14200
BASE_PORT_FRONTEND=14400

# New nodes install WEKA from the RUNNING CLUSTER's dist endpoint (always the
# cluster's current version, even after manual upgrades). The S3/URL settings
# are only fallbacks if no member serves the dist; usually leave both empty.
WEKA_INSTALL_S3=""
WEKA_INSTALL_URL=""
# Credentials are read from Secrets Manager (weka/<cluster>/admin, written by
# day-0) when available; these values are the FALLBACK if the secret is absent.
WEKA_USER="admin"
WEKA_PASS="admin"
ADMIN_SECRET_NAME=""        # default: weka/<cluster>/admin

JOIN_COUNT=5
SSM_TIMEOUT=1200
CLOUDWATCH_OUTPUT=true
DEBUG=false

# how long to wait for data redistribution / rebuild during scale-in & replace
DRAIN_TIMEOUT=7200          # seconds per node
BASELINE_PARAM="/weka/${CLUSTER_NAME}/baseline"

# ---- operational override knobs (settable here or per-run via env) ---------
ORIGINAL_SIZE="${ORIGINAL_SIZE:-}"   # scale-in floor; ONLY if the baseline SSM parameter is missing
NODE_IP="${NODE_IP:-}"               # mgmt IP of a terminated node the EC2 API can no longer resolve (replace)

###############################################################################
# weka.conf overlay -- if present, values there OVERRIDE the defaults above.
# Workstation: ./weka.conf (package root). Nodes: /tmp/weka.conf (shipped by
# deploy.sh). See RUNBOOK §4.
for _c in ./weka.conf /tmp/weka.conf; do [ -f "$_c" ] && . "$_c" || true; done
DISCOVERY_TAG_VALUE="${CLUSTER_NAME}"
BASELINE_PARAM="/weka/${CLUSTER_NAME}/baseline"

###############################################################################
##                     NODE PAYLOAD (runs on target nodes)                   ##
###############################################################################
# Identical discovery/setup logic to day-0; differences:
#   - 'drives-join' creates drives0 WITH --join-ips (joins existing cluster)
#   - 'drain-local' wipes local containers on a removed node

NODE_PAYLOAD=$(cat <<'NODE_EOF'
#!/usr/bin/env bash
set -eu
source /tmp/weka_node.env
[ "${DEBUG}" = "true" ] && set -x

PHASE="${1:?usage: weka_node.sh <phase>}"
TOPO_CACHE=/tmp/weka_topology.env

imds_tok() { curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
             -H "X-aws-ec2-metadata-token-ttl-seconds: 300"; }
imds() { curl -sf -H "X-aws-ec2-metadata-token: $(imds_tok)" \
         "http://169.254.169.254/latest/$1"; }

ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a<<24)+(b<<16)+(c<<8)+d )); }
int2ip() { local i=$1; echo "$(( (i>>24)&255 )).$(( (i>>16)&255 )).$(( (i>>8)&255 )).$(( i&255 ))"; }
expand_cpulist() {
  local out=() part
  IFS=, read -ra parts <<<"$1"
  for part in "${parts[@]}"; do
    if [[ "$part" == *-* ]]; then
      for ((i=${part%-*}; i<=${part#*-}; i++)); do out+=("$i"); done
    else out+=("$part"); fi
  done
  echo "${out[*]}"
}

discover() {
  [ -f "$TOPO_CACHE" ] && { source "$TOPO_CACHE"; return; }
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

  local node cpu sib first reserved
  reserved=" $(cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list | tr ',' ' ' ) "
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

net_args() {
  local nic ip args=""
  for nic in $1; do
    ip=$(ip -br addr show dev "$nic" | grep -Eo '[0-9.]{7,15}' | head -1)
    args+=" --net ${nic}/${ip}/${DP_NETMASK}/${DP_GATEWAY}"
  done
  echo "$args"
}

mem_gb() { awk -v c="$1" -v r="$2" 'BEGIN{printf "%g", c*r}'; }

setup_container() {
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
      # Prefer the RUNNING CLUSTER's own distribution endpoint: it always
      # matches the cluster's exact current version, including any upgrades
      # applied since day-0. WEKA_INSTALL_URL is only a fallback.
      got=""
      for ip in ${JOIN_IPS//,/ }; do
        if curl -skf -m 30 "https://${ip}:${BASE_PORT_DRIVES}/dist/v1/install" -o /tmp/weka_dist_install \
        || curl -sf  -m 30 "http://${ip}:${BASE_PORT_DRIVES}/dist/v1/install"  -o /tmp/weka_dist_install; then
          got="$ip"; break
        fi
      done
      if [ -n "$got" ]; then
        echo "installing weka from cluster member ${got} (version-matched)"
        sh /tmp/weka_dist_install
      elif [ -n "${WEKA_INSTALL_S3}" ]; then
        echo "WARN: no cluster member served the dist -- falling back to ${WEKA_INSTALL_S3} (version may not match a manually upgraded cluster)"
        cd /tmp && aws s3 cp "${WEKA_INSTALL_S3}" weka_dist --no-progress
        if file weka_dist | grep -qi 'shell script\|ascii text'; then sh weka_dist
        else mkdir -p weka_dist_x && tar xf weka_dist -C weka_dist_x --strip-components=1 \
             && cd weka_dist_x && ./install.sh; fi
      elif [ -n "${WEKA_INSTALL_URL}" ]; then
        echo "WARN: no cluster member served the dist -- falling back to WEKA_INSTALL_URL (version may not match a manually upgraded cluster)"
        cd /tmp && curl -fsSL "${WEKA_INSTALL_URL}" -o weka_dist
        if file weka_dist | grep -qi 'shell script\|ascii text'; then sh weka_dist
        else mkdir -p weka_dist_x && tar xf weka_dist -C weka_dist_x --strip-components=1 \
             && cd weka_dist_x && ./install.sh; fi
      else
        echo "FATAL: could not fetch the weka dist from any cluster member and WEKA_INSTALL_URL is empty"; exit 1
      fi
    else
      echo "weka agent present, skipping install"
    fi
    command -v weka >/dev/null 2>&1 || { echo "FATAL: weka CLI not installed"; exit 1; }
    ;;
  cleanup)
    weka local ps 2>/dev/null | grep -qi drives0 && { echo "FATAL: cluster containers already present on this node"; exit 1; }
    weka local stop -f  || true
    weka local rm --all -f || true
    rm -f "$TOPO_CACHE"
    ;;
  drives-join)
    discover
    setup_container drives0 --only-drives-cores "$BASE_PORT_DRIVES" \
      "$DRIVE_CORES" "$DRIVE_CORE_IDS" "$(mem_gb "$DRIVE_CORES" "$DRIVE_RAM_PER_CORE_GB")" \
      "$DRIVE_NICS" 1
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
  drain-local)
    weka local stop -f || true
    weka local rm --all -f || true
    rm -f "$TOPO_CACHE"
    ;;
  *)
    echo "unknown phase: $PHASE"; exit 1;;
esac
NODE_EOF
)

###############################################################################
##                            ORCHESTRATOR LOGIC                             ##
###############################################################################

log()  { echo -e "\n=== $* ==="; }
die()  { echo "FATAL: $*" >&2; exit 1; }

OP="${1:-status}"; shift || true

# ---- ensure AWS CLI + jq ----
for tool in awscli:aws jq:jq; do
  pkg="${tool%%:*}"; cmd="${tool##*:}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd missing -- installing"
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -q >/dev/null 2>&1 || true
      apt-get install -yq "$pkg" >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then dnf install -yq "$pkg" >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then yum install -yq "$pkg" >/dev/null 2>&1 || true
    fi
    if [ "$cmd" = "aws" ] && ! command -v aws >/dev/null 2>&1; then
      # RHEL-family base repos lack awscli (EPEL-only) -- official v2 bundle
      command -v unzip >/dev/null 2>&1 || dnf install -yq unzip >/dev/null 2>&1 || yum install -yq unzip >/dev/null 2>&1 || apt-get install -yq unzip >/dev/null 2>&1 || true
      curl -sf "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip \
        && unzip -qo /tmp/awscliv2.zip -d /tmp/awscliv2 \
        && /tmp/awscliv2/aws/install >/dev/null 2>&1 || true
      rm -rf /tmp/awscliv2 /tmp/awscliv2.zip
    fi
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd unavailable and could not be installed"
  fi
done

IMDS_TOK=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
           -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
imds() { curl -sf -H "X-aws-ec2-metadata-token: ${IMDS_TOK}" \
         "http://169.254.169.254/latest/$1"; }
SELF_ID=$(imds meta-data/instance-id)
REGION=$(imds meta-data/placement/region)
export AWS_DEFAULT_REGION="$REGION"

command -v weka >/dev/null 2>&1 || die "run this on a cluster member node (weka CLI not found)"

# ---- credentials: prefer the Secrets Manager secret written by day-0 ----
SECRET_NAME="${ADMIN_SECRET_NAME:-weka/${CLUSTER_NAME}/admin}"
SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" \
  --query SecretString --output text 2>/dev/null || true)
if [ -n "$SECRET_JSON" ]; then
  WEKA_USER=$(jq -r '.username // "admin"' <<<"$SECRET_JSON")
  WEKA_PASS=$(jq -r '.password' <<<"$SECRET_JSON")
  echo "using credentials from Secrets Manager: ${SECRET_NAME}"
else
  echo "WARN: secret ${SECRET_NAME} not readable -- falling back to configured WEKA_USER/WEKA_PASS"
fi
weka user login "$WEKA_USER" "$WEKA_PASS" >/dev/null || die "weka login failed"

# ---- tagged instances (id ip name), sorted by instance-id ----
mapfile -t TAGGED < <(aws ec2 describe-instances \
  --filters "Name=tag:${DISCOVERY_TAG_KEY},Values=${DISCOVERY_TAG_VALUE}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress,PrivateDnsName]' \
  --output text | sort)

# ---- cluster membership via JSON (-J): named fields, not column positions ----
# rows: <numeric-host-id> <first-ip> <container-name> <hostname>
member_table() {
  weka cluster container -J | jq -r \
    '.[] | select(.mode=="backend")
     | [(.host_id | capture("<(?<n>[0-9]+)>").n), .ips[0], .container_name, .hostname] | @tsv'
}
member_ips() { member_table | awk '{print $2}' | sort -u; }

cluster_ok() {  # healthy AND fully protected (0-failure protection state at 100%)
  local s; s=$(weka status -J 2>/dev/null) || return 1
  [ "$(jq -r '.status' <<<"$s")" = "OK" ] || return 1
  [ "$(jq -r '[.rebuild.protectionState[] | select(.numFailures==0)][0].percent' <<<"$s")" = "100" ] || return 1
  return 0
}

wait_cluster_ok() {  # $1 = timeout seconds, $2 = context msg
  local deadline=$(( $(date +%s) + $1 ))
  until cluster_ok; do
    [ $(date +%s) -gt $deadline ] && die "timed out waiting for cluster OK + fully protected ($2)"
    echo "  waiting for cluster OK + fully protected ($2)..."; sleep 20
  done
}

stripe_info() {  # echoes "data parity spares"
  weka status -J | jq -r '"\(.stripe_data_drives // 0) \(.stripe_protection_drives // 0) \(.hot_spare // 0)"'
}

original_size() {
  if [ -n "${ORIGINAL_SIZE:-}" ]; then echo "$ORIGINAL_SIZE"; return; fi
  local v
  v=$(aws ssm get-parameter --name "$BASELINE_PARAM" --query 'Parameter.Value' --output text 2>/dev/null) || \
    die "baseline parameter $BASELINE_PARAM not found -- pass ORIGINAL_SIZE=<n> explicitly"
  grep -oE '"original_nodes": *[0-9]+' <<<"$v" | grep -oE '[0-9]+'
}

# ---- SSM fan-out (same mechanics as day-0) ----
ENV_B64=""; PAYLOAD_B64=""
build_payload() {
  local join_ips="$1"
  local env; env=$(cat <<ENV_EOF
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
JOIN_IPS="${join_ips}"
WEKA_INSTALL_S3="${WEKA_INSTALL_S3}"
WEKA_INSTALL_URL="${WEKA_INSTALL_URL}"
WEKA_USER="${WEKA_USER}"
WEKA_PASS="${WEKA_PASS}"
ENV_EOF
)
  ENV_B64=$(base64 -w0 <<<"$env")
  PAYLOAD_B64=$(base64 -w0 <<<"$NODE_PAYLOAD")
}

CW_ARGS=()
[ "$CLOUDWATCH_OUTPUT" = "true" ] && \
  CW_ARGS=(--cloud-watch-output-config "CloudWatchOutputEnabled=true,CloudWatchLogGroupName=/weka/day2/${CLUSTER_NAME}")

run_phase() {
  local phase=$1; shift
  local ids=("$@")
  log "Phase '${phase}' on ${#ids[@]} node(s): ${ids[*]}"
  local cmd="echo ${ENV_B64} | base64 -d > /tmp/weka_node.env && echo ${PAYLOAD_B64} | base64 -d > /tmp/weka_node.sh && sudo -E bash /tmp/weka_node.sh ${phase}"
  local cmd_id
  cmd_id=$(aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --instance-ids "${ids[@]}" \
    --comment "weka ${CLUSTER_NAME} day2 ${phase}" \
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
        echo "--- ${iid} output tail ---"
        aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$iid" \
          --query '[StandardOutputContent,StandardErrorContent]' --output text | tail -40
      done
      exit 1
    fi
    [ $pending -eq 0 ] && break
    [ $(date +%s) -gt $deadline ] && die "phase '${phase}' timed out"
    sleep 10
  done
  log "Phase '${phase}' complete"
}

wait_ssm_online() {
  local ids=("$@") online
  local deadline=$(( $(date +%s) + 600 ))
  while :; do
    online=$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$(IFS=,; echo "${ids[*]}")" \
      --query 'length(InstanceInformationList[?PingStatus==`Online`])' --output text)
    [ "$online" = "${#ids[@]}" ] && break
    [ $(date +%s) -gt $deadline ] && die "only ${online}/${#ids[@]} SSM-online"
    echo "  ${online}/${#ids[@]} SSM-online..."; sleep 10
  done
}

# ---- node bookkeeping helpers ----
node_ip()   { printf '%s\n' "${TAGGED[@]}" | awk -v id="$1" '$1==id{print $2}'; }
node_containers() {  # $1 = mgmt ip -> "cid role" lines
  member_table | awk -v ip="$1" '{gsub(/,.*/,"",$2)} $2==ip {print $1, $3}'
}
# NB: `drive deactivate` accepts numeric disk ids; `drive remove` requires UUIDs
node_disk_ids() {
  weka cluster drive -J | jq -r --arg h "$1" \
    '.[] | select(.hostname==$h) | .disk_id | capture("<(?<n>[0-9]+)>").n'
}
node_drive_uuids() {
  weka cluster drive -J | jq -r --arg h "$1" '.[] | select(.hostname==$h) | .uuid'
}
resolve_ip() {  # iid -> private ip; works for dead/terminated nodes via fallbacks
  local iid=$1 ip
  ip=$(node_ip "$iid")
  [ -n "$ip" ] || ip=$(aws ec2 describe-instances --instance-ids "$iid" \
    --query 'Reservations[].Instances[].PrivateIpAddress' --output text 2>/dev/null | head -1)
  [ -n "$ip" ] && [ "$ip" != "None" ] || ip="${NODE_IP:-}"
  [ -n "$ip" ] || die "cannot resolve private IP of ${iid} (terminated?) -- re-run with NODE_IP=<mgmt-ip>"
  echo "$ip"
}
untag_node() {  # re-tag so discovery never re-adopts (CreateTags is IAM-allowed)
  aws ec2 create-tags --resources "$1" \
    --tags "Key=${DISCOVERY_TAG_KEY},Value=${DISCOVERY_TAG_VALUE}-removed" \
    "Key=weka-drain,Value=done" 2>/dev/null \
    || echo "WARN: could not re-tag $1 -- remove its ${DISCOVERY_TAG_KEY} tag manually"
}

remove_node_from_cluster() {  # $1=iid  $2=reachable(0/1)
  local iid=$1 reachable=$2 ip cids drives_cid drive_ids c role
  ip=$(resolve_ip "$iid")
  log "Removing ${iid} (${ip}) from cluster (reachable=${reachable})"

  drives_cid=""
  local containers; containers=$(node_containers "$ip")
  [ -n "$containers" ] || die "no cluster containers found for ${iid} (${ip}) -- not a member?"
  while read -r c role; do
    [ "$role" = "drives0" ] && drives_cid="$c"
  done <<<"$containers"

  local host="ip-${ip//./-}"
  if [ -n "$drives_cid" ]; then
    drive_ids=$(node_disk_ids "$host" | tr '\n' ' ')
    local drive_uuids; drive_uuids=$(node_drive_uuids "$host" | tr '\n' ' ')
    if [ -n "${drive_ids// }" ]; then
      log "Deactivating drives of ${iid} (${host}): ${drive_ids}"
      weka cluster drive deactivate $drive_ids --force
      local deadline=$(( $(date +%s) + DRAIN_TIMEOUT ))
      while :; do
        local remaining
        remaining=$(weka cluster drive -J | jq --arg h "$host" \
          '[.[] | select(.hostname==$h and .status!="INACTIVE" and .status!="DOWN")] | length')
        [ "$remaining" = "0" ] && break
        [ $(date +%s) -gt $deadline ] && die "drive drain timed out on ${iid}"
        echo "  ${remaining} drive(s) still draining on ${iid}..."; sleep 20
      done
      log "Removing drained drives"
      weka cluster drive remove $drive_uuids --force
    fi
  fi

  log "Deactivating + removing containers of ${iid}"
  while read -r c role; do
    weka cluster container deactivate "$c" || true
  done <<<"$containers"
  sleep 10
  while read -r c role; do
    weka cluster container remove "$c" || weka cluster container remove "$c" --force
  done <<<"$containers"

  if [ "$reachable" = "1" ]; then
    build_payload ""
    run_phase drain-local "$iid"
  else
    echo "  (node unreachable -- skipping local wipe)"
  fi
  untag_node "$iid"
  log "${iid} removed. Safe to terminate the EC2 instance."
}

scale_out() {
  # REQUIRE_OK=0 (set by replace) skips health gates: adding a node to a
  # degraded cluster is exactly what a replacement does
  local require_ok="${REQUIRE_OK:-1}"
  mapfile -t MEMBER_IPS < <(member_ips)
  local new_ids=() new_line id ip
  for new_line in "${TAGGED[@]}"; do
    id=$(awk '{print $1}' <<<"$new_line"); ip=$(awk '{print $2}' <<<"$new_line")
    printf '%s\n' "${MEMBER_IPS[@]}" | grep -qx "$ip" || new_ids+=("$id")
  done
  [ ${#new_ids[@]} -gt 0 ] || { log "No tagged non-member nodes found -- nothing to do"; return 0; }
  log "Scale-out: adopting ${#new_ids[@]} node(s): ${new_ids[*]}"
  if [ "$require_ok" = "1" ]; then
    cluster_ok || die "cluster not OK + fully protected -- fix health before scaling out"
  fi
  wait_ssm_online "${new_ids[@]}"
  local join; join=$(printf '%s\n' "${MEMBER_IPS[@]}" | head -n "$JOIN_COUNT" | paste -sd, -)
  build_payload "$join"
  run_phase install     "${new_ids[@]}"
  run_phase cleanup     "${new_ids[@]}"
  run_phase drives-join "${new_ids[@]}"
  run_phase compute     "${new_ids[@]}"
  run_phase frontend    "${new_ids[@]}"
  run_phase adddrives   "${new_ids[@]}"
  if [ "$require_ok" = "1" ]; then
    wait_cluster_ok 1800 "post scale-out rebalance"
    log "Scale-out complete"; weka status
  else
    log "Scale-out (degraded mode) complete -- health wait deferred to caller"
  fi
}

scale_in() {
  local victims=("$@")
  [ ${#victims[@]} -gt 0 ] || die "usage: $0 scale-in <instance-id> [...]"
  mapfile -t MEMBER_IPS < <(member_ips)
  local members=${#MEMBER_IPS[@]} after=$(( ${#MEMBER_IPS[@]} - ${#victims[@]} ))
  local floor; floor=$(original_size)
  read -r D P H <<<"$(stripe_info)"
  log "Scale-in: ${members} members -> ${after}; floor=${floor} (original), stripe=${D}+${P}, hot-spare FDs=${H}"
  [ "$after" -ge "$floor" ] || die "refusing: WEKA does not support shrinking below the original cluster size (${floor})"
  [ "$after" -ge $(( D + P + H )) ] || die "refusing: ${after} nodes cannot sustain stripe ${D}+${P} with ${H} hot-spare FD(s)"
  for iid in "${victims[@]}"; do
    [ "$iid" = "$SELF_ID" ] && die "refusing to remove the node this script is running on -- run it elsewhere"
    [ -n "$(node_ip "$iid")" ] || die "${iid} is not a tagged running instance"
  done
  cluster_ok || die "cluster not OK + fully protected -- fix health before scaling in"
  for iid in "${victims[@]}"; do
    remove_node_from_cluster "$iid" 1
    wait_cluster_ok "$DRAIN_TIMEOUT" "after removing ${iid}"
  done
  log "Scale-in complete"; weka status
}

replace_node() {
  local failed="${1:-}"; local mode="${2:---add-first}"
  [ -n "$failed" ] || die "usage: $0 replace <failed-instance-id> [--add-first|--remove-first]"
  [ "$failed" = "$SELF_ID" ] && die "cannot replace the node this script runs on -- run it elsewhere"
  local reachable=0 state
  state=$(aws ec2 describe-instances --instance-ids "$failed" \
    --query 'Reservations[].Instances[].State.Name' --output text 2>/dev/null || echo "unknown")
  if [ "$state" = "running" ]; then
    local ping
    ping=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=${failed}" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)
    [ "$ping" = "Online" ] && reachable=1
  fi
  log "Replace ${failed}: ec2-state=${state} reachable=${reachable} mode=${mode}"

  if [ "$mode" = "--remove-first" ]; then
    remove_node_from_cluster "$failed" "$reachable"
    log "Failed node removed. Launch the replacement instance (same launch template),"
    log "wait for it to be running, then run: $0 scale-out"
  else
    # add-first: replacement must already be launched (tagged, not a member).
    # Health gates off: the cluster is degraded until the dead node is gone.
    REQUIRE_OK=0 scale_out
    remove_node_from_cluster "$failed" "$reachable"
    wait_cluster_ok "$DRAIN_TIMEOUT" "post replace"
    log "Replace complete"; weka status
  fi
}

status_report() {
  log "Cluster status"
  weka status || true
  log "Baseline"
  aws ssm get-parameter --name "$BASELINE_PARAM" --query 'Parameter.Value' --output text 2>/dev/null \
    || echo "(no baseline parameter at ${BASELINE_PARAM})"
  log "Tagged running instances vs membership"
  mapfile -t MEMBER_IPS < <(member_ips)
  local line id ip
  for line in "${TAGGED[@]}"; do
    id=$(awk '{print $1}' <<<"$line"); ip=$(awk '{print $2}' <<<"$line")
    if printf '%s\n' "${MEMBER_IPS[@]}" | grep -qx "$ip"; then
      echo "  MEMBER      $id  $ip"
    else
      echo "  NOT-MEMBER  $id  $ip   (scale-out candidate)"
    fi
  done
  echo "  members=${#MEMBER_IPS[@]} tagged=${#TAGGED[@]}"
}

case "$OP" in
  scale-out) scale_out ;;
  scale-in)  scale_in "$@" ;;
  replace)   replace_node "$@" ;;
  status)    status_report ;;
  *) die "usage: $0 {scale-out|scale-in <iid>...|replace <iid> [--add-first|--remove-first]|status}" ;;
esac
