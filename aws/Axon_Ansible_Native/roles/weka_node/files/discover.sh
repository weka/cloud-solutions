#!/usr/bin/env bash
# discover.sh -- runtime topology discovery for the native path.
#
# The validated topology discovery, unchanged from its original battle-tested form
# (NUMA-paired core/NIC allocation, pin/exclude, NVMe selection with in-use
# skipping and block-device enumeration, NIC role split, topology cache).
# Inputs arrive via environment (same names as weka.conf); output is one
# JSON object on the last line for Ansible to consume as host facts.
# The /tmp/weka_topology.env cache is kept for parity: later phases and the
# bash path read the same cache.
set -eu

# ---- inputs (env, with the same defaults as the installer) ----
DRIVE_CORES="${DRIVE_CORES:-1}"
COMPUTE_CORES="${COMPUTE_CORES:-1}"
FRONTEND_CORES="${FRONTEND_CORES:-1}"
DRIVES_PER_NODE="${DRIVES_PER_NODE:-0}"
WEKA_CORE_IDS="${WEKA_CORE_IDS:-}"
EXCLUDED_CORE_IDS="${EXCLUDED_CORE_IDS:-}"
MGMT_NETWORK_CARD="${MGMT_NETWORK_CARD:-0}"
MGMT_DEVICE_INDEX="${MGMT_DEVICE_INDEX:-0}"
TOPO_CACHE="${TOPO_CACHE:-/tmp/weka_topology.env}"

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

# ---- run + emit JSON (single line, last line of output) ----
discover
json_list() { local out="" x; for x in $1; do out+="\"$x\","; done; echo "[${out%,}]"; }
printf '{"mgmt_nic":"%s","mgmt_ip":"%s","dp_netmask":"%s","dp_gateway":"%s","failure_domain":"%s","weka_cpuspec":"%s","drive_core_ids":"%s","compute_core_ids":"%s","frontend_core_ids":"%s","drive_nics":%s,"compute_nics":%s,"frontend_nics":%s,"weka_drives":%s,"weka_nics":%s,"drive_net_args":"%s","compute_net_args":"%s","frontend_net_args":"%s"}\n' \
  "$MGMT_NIC" "$MGMT_IP" "$DP_NETMASK" "$DP_GATEWAY" "$FAILURE_DOMAIN" "$WEKA_CPUSPEC" \
  "$DRIVE_CORE_IDS" "$COMPUTE_CORE_IDS" "$FRONTEND_CORE_IDS" \
  "$(json_list "$DRIVE_NICS")" "$(json_list "$COMPUTE_NICS")" "$(json_list "$FRONTEND_NICS")" \
  "$(json_list "$WEKA_DRIVES")" "$(json_list "$WEKA_NICS")" \
  "$(net_args "$DRIVE_NICS")" "$(net_args "$COMPUTE_NICS")" "$(net_args "$FRONTEND_NICS")"
