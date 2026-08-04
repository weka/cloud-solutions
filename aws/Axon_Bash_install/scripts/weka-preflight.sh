#!/usr/bin/env bash
# weka-preflight.sh -- AMI / node conformance check for WEKA deployment.
# Run on each candidate node (via SSM or shell) BEFORE the day-0 installer:
#   every failure here is one the installer would otherwise hit mid-flight.
# Exit 0 = all checks pass (warnings allowed); exit 1 = at least one FAIL.
#
set -uo pipefail

# weka.conf overlay: carve/threshold values from the shared config (RUNBOOK §4)
for _c in ./weka.conf /tmp/weka.conf; do [ -f "$_c" ] && . "$_c" || true; done

###############################################################################
##                        CUSTOMER CONFIGURATION                             ##
##  Thresholds for this deployment. Settable here or per-run via env.       ##
###############################################################################
WEKA_MAX_KERNEL="${WEKA_MAX_KERNEL:-6.8}"       # highest kernel line the target WEKA version builds on
# derived from the carve when weka.conf supplies it; else default 3
MIN_DATA_NICS="${MIN_DATA_NICS:-$(( ${DRIVE_CORES:-1} + ${COMPUTE_CORES:-1} + ${FRONTEND_CORES:-1} ))}"
MIN_PHYS_CORES="${MIN_PHYS_CORES:-4}"           # carve total + 1 reserved for OS
MIN_FREE_GB="${MIN_FREE_GB:-26}"                # free space needed on the /opt filesystem
MGMT_NETWORK_CARD="${MGMT_NETWORK_CARD:-0}"     # must match the generated template layout
MGMT_DEVICE_INDEX="${MGMT_DEVICE_INDEX:-0}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN+1)); }
bad()  { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }

SUDO=""; [ "$(id -u)" != 0 ] && SUDO="sudo"
have() { command -v "$1" >/dev/null 2>&1; }
APT_UPDATED=0
pkg_installable() {  # best-effort dry-run check that a package is available
  if have apt-get; then
    # fresh nodes have stale/empty package lists; refresh once like the installer does
    [ "$APT_UPDATED" = 0 ] && { $SUDO apt-get update -q >/dev/null 2>&1 || true; APT_UPDATED=1; }
    apt-get install --dry-run -yq "$1" >/dev/null 2>&1
  elif have dnf; then dnf install --assumeno "$1" >/dev/null 2>&1 || dnf list "$1" >/dev/null 2>&1
  elif have yum; then yum list "$1" >/dev/null 2>&1
  else return 1; fi
}

echo "##### WEKA preflight -- $(hostname) -- $(date -u +%FT%TZ) #####"

# ---------- 1. kernel ceiling ----------
KREL=$(uname -r); KLINE=$(echo "$KREL" | grep -oE '^[0-9]+\.[0-9]+')
if [ "$(printf '%s\n%s\n' "$KLINE" "$WEKA_MAX_KERNEL" | sort -V | tail -1)" = "$WEKA_MAX_KERNEL" ]; then
  ok "kernel ${KREL} is <= ${WEKA_MAX_KERNEL} (WEKA driver build ceiling)"
else
  bad "kernel ${KREL} EXCEEDS WEKA ceiling ${WEKA_MAX_KERNEL} -- WEKA drivers will not compile. Pin an older kernel (e.g. Ubuntu 24.04: linux-image-aws-lts-24.04 = 6.8) or use a different AMI"
fi

# ---------- 2. kernel headers ----------
if [ -d "/usr/src/linux-headers-${KREL}" ] || [ -d "/usr/src/kernels/${KREL}" ]; then
  ok "kernel headers for ${KREL} present"
elif have apt-get && pkg_installable "linux-headers-${KREL}"; then
  ok "kernel headers for ${KREL} installable via apt"
elif { have dnf || have yum; } && pkg_installable "kernel-devel-${KREL}" ; then
  ok "kernel-devel for the running kernel installable"
else
  # EL point-release drift: live repos may have rolled past this AMI's release
  # and dropped kernel-devel for its running kernel -- the installer falls
  # back to the distro vault (Rocky/Alma); pass if that RPM is reachable
  _ID=$(. /etc/os-release 2>/dev/null; echo "${ID:-}")
  _PR=$(echo "$KREL" | grep -oE 'el[0-9]+_[0-9]+' | sed 's/el//; s/_/./')
  _VURL=""
  case "$_ID" in
    rocky)     _VURL="https://dl.rockylinux.org/vault/rocky/${_PR}/AppStream/$(uname -m)/os/Packages/k/kernel-devel-${KREL}.rpm" ;;
    almalinux) _VURL="https://repo.almalinux.org/vault/${_PR}/AppStream/$(uname -m)/os/Packages/kernel-devel-${KREL}.rpm" ;;
  esac
  if [ -n "$_VURL" ] && curl -sf -m 10 -r 0-0 -o /dev/null "$_VURL"; then
    ok "kernel-devel-${KREL}: dropped from live repos (point-release drift) but available in the ${_ID} vault (installer self-installs it)"
  else
    bad "kernel headers for ${KREL} neither present nor installable -- WEKA driver build will fail. Bake kernel-devel matching the AMI kernel into the image, or update+reboot to the current kernel"
  fi
fi

# ---------- 3. compiler matching the kernel build ----------
KGCC=$(grep -oE 'gcc-[0-9]+' /proc/version | head -1 || true)
if [ -n "$KGCC" ]; then
  if have "$KGCC"; then ok "kernel compiler ${KGCC} present"
  elif pkg_installable "$KGCC"; then ok "kernel compiler ${KGCC} installable"
  else bad "kernel was built with ${KGCC}, which is neither installed nor installable"
  fi
else
  have gcc && ok "gcc present (kernel compiler string not detected)" \
           || { pkg_installable gcc && ok "gcc installable" || bad "no gcc present or installable"; }
fi
have make || pkg_installable make || bad "make neither present nor installable"

# ---------- 4. tooling: awscli, jq ----------
for t in awscli:aws jq:jq; do
  pkg="${t%%:*}"; cmd="${t##*:}"
  if have "$cmd"; then ok "$cmd present"
  elif pkg_installable "$pkg"; then ok "$cmd installable via package manager"
  # RHEL-family repos lack awscli (EPEL-only) -- the installer falls back to
  # the official AWS CLI v2 bundle; pass if that is reachable
  elif [ "$cmd" = "aws" ] && curl -sf -m 8 -r 0-0 -o /dev/null \
       "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip"; then
    ok "aws: not in distro repos; official AWS CLI v2 bundle reachable (installer self-installs it)"
  else bad "$cmd neither present nor installable (needed by installer/day-2)"
  fi
done

# ---------- 5. IMDSv2 + hop limit ----------
TOK=$(curl -sf -m 5 -X PUT http://169.254.169.254/latest/api/token \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)
if [ -n "$TOK" ]; then
  ok "IMDSv2 token obtained"
  IID=$(curl -sf -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/instance-id)
  REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/placement/region)
  if have aws; then
    HOP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
      --query 'Reservations[0].Instances[0].MetadataOptions.HttpPutResponseHopLimit' --output text 2>/dev/null || echo "?")
    if [ "$HOP" = "?" ]; then warn "could not read IMDS hop limit (IAM ec2:DescribeInstances missing?)"
    elif [ "$HOP" -ge 2 ] 2>/dev/null; then ok "IMDS hop limit ${HOP} >= 2 (required by WEKA containers)"
    else bad "IMDS hop limit ${HOP} < 2 -- WEKA containers will fail IMDS. Set HttpPutResponseHopLimit=2 in the launch template"
    fi
  else
    warn "aws CLI absent -- skipping IMDS hop-limit check (verify HttpPutResponseHopLimit=2 in template)"
  fi
else
  bad "IMDSv2 unavailable -- installer topology discovery will fail"
  REGION=""
fi

# ---------- 6. NIC layout ----------
# NB: a running WEKA cluster binds data NICs/NVMe to DPDK (igb_uio), hiding
# them from sysfs -- device checks are only meaningful pre-install.
WEKA_ACTIVE=0
have weka && weka local ps 2>/dev/null | grep -qi Running && WEKA_ACTIVE=1
ENA=0; MGMT_FOUND=0
for d in /sys/class/net/*; do
  n=$(basename "$d"); [ "$n" = lo ] && continue
  [ -e "$d/device/driver" ] || continue
  [ "$(basename "$(readlink -f "$d/device/driver")")" = "ena" ] && ENA=$((ENA+1))
done
if [ -n "${TOK:-}" ]; then
  for mac in $(curl -sf -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/network/interfaces/macs/ | tr -d '/'); do
    card=$(curl -sf -H "X-aws-ec2-metadata-token: $TOK" "http://169.254.169.254/latest/meta-data/network/interfaces/macs/$mac/network-card" 2>/dev/null || echo 0)
    dev=$(curl -sf -H "X-aws-ec2-metadata-token: $TOK" "http://169.254.169.254/latest/meta-data/network/interfaces/macs/$mac/device-number")
    [ "$card" = "$MGMT_NETWORK_CARD" ] && [ "$dev" = "$MGMT_DEVICE_INDEX" ] && MGMT_FOUND=1
  done
fi
[ "$MGMT_FOUND" = 1 ] && ok "mgmt ENI found at card ${MGMT_NETWORK_CARD} / dev ${MGMT_DEVICE_INDEX}" \
                      || bad "no ENI at card ${MGMT_NETWORK_CARD} / dev ${MGMT_DEVICE_INDEX} -- must match installer MGMT_* settings"
DATA=$((ENA-1))
if [ "$DATA" -ge "$MIN_DATA_NICS" ]; then
  ok "data-plane ENA NICs: ${DATA} >= ${MIN_DATA_NICS}"
elif [ "$WEKA_ACTIVE" = 1 ]; then
  warn "data-plane NIC count not evaluable -- NICs are DPDK-bound by the running WEKA cluster"
else
  bad "only ${DATA} data-plane ENA NICs (need >= ${MIN_DATA_NICS}) -- check launch template ENI layout"
fi
EFA=$(ls -d /sys/class/infiniband/* 2>/dev/null | wc -l | xargs)
echo "[INFO] EFA/RDMA devices visible: ${EFA}"

# ---------- 7. instance-store NVMe ----------
NVME=0
for c in /sys/class/nvme/nvme[0-9]*; do
  [ -e "$c/model" ] || continue
  grep -qi "Instance Storage" "$c/model" && NVME=$((NVME+1))
done
MIN_NVME="${DRIVES_PER_NODE:-0}"; [ "$MIN_NVME" -gt 0 ] 2>/dev/null || MIN_NVME=1
if [ "$NVME" -ge "$MIN_NVME" ]; then
  ok "instance-store NVMe drives: ${NVME} >= ${MIN_NVME} required"
elif [ "$NVME" -gt 0 ]; then
  bad "only ${NVME} instance-store NVMe drives but DRIVES_PER_NODE=${MIN_NVME} configured"
elif [ "$WEKA_ACTIVE" = 1 ]; then
  warn "instance-store NVMe not evaluable -- drives are DPDK-bound by the running WEKA cluster"
else
  bad "no instance-store NVMe found (model 'Amazon EC2 NVMe Instance Storage') -- WEKA drives phase will fail"
fi

# ---------- 8. cores / memory ----------
PHYS=$(lscpu -p=core,socket 2>/dev/null | grep -v '^#' | sort -u | wc -l | xargs)
[ "$PHYS" -ge "$MIN_PHYS_CORES" ] && ok "physical cores: ${PHYS} >= ${MIN_PHYS_CORES}" \
                                  || bad "only ${PHYS} physical cores (need >= ${MIN_PHYS_CORES} for carve + OS core)"
# ---- memory: carve requirement vs actually-available, + hugepage pre-reservations ----
# The WEKA agent allocates its own hugepages from the container --memory
# sizing; these checks verify the box can actually satisfy that.
MEMG=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
MEM_AVAIL_GB=$(( $(grep MemAvailable /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
CARVE_NEED=$(awk -v d="${DRIVE_CORES:-1}" -v c="${COMPUTE_CORES:-1}" -v f="${FRONTEND_CORES:-1}"   -v dr="${DRIVE_RAM_PER_CORE_GB:-2.5}" -v cr="${COMPUTE_RAM_PER_CORE_GB:-8}" -v fr="${FRONTEND_RAM_PER_CORE_GB:-2.5}"   'BEGIN{printf "%d", d*dr + c*cr + f*fr + 2}')   # +2 GB agent overhead
if [ "$MEM_AVAIL_GB" -ge $(( CARVE_NEED + 8 )) ]; then
  ok "memory: ${MEM_AVAIL_GB} GiB available >= ${CARVE_NEED} GiB carve requirement + 8 GiB OS headroom (total ${MEMG} GiB)"
elif [ "$MEM_AVAIL_GB" -ge "$CARVE_NEED" ]; then
  warn "memory tight: ${MEM_AVAIL_GB} GiB available vs ${CARVE_NEED} GiB carve requirement -- little OS headroom"
else
  bad "insufficient memory: ${MEM_AVAIL_GB} GiB available < ${CARVE_NEED} GiB required by the carve (DRIVE/COMPUTE/FRONTEND cores x RAM-per-core) -- container setup will fail"
fi
HP_TOTAL=$(grep -E '^HugePages_Total' /proc/meminfo | awk '{print $2}')
if [ "${HP_TOTAL:-0}" -gt 0 ] && [ "$WEKA_ACTIVE" = 1 ]; then
  ok "hugepages present are WEKA's own (cluster running on this node)"
elif [ "${HP_TOTAL:-0}" -gt 0 ]; then
  HP_KB=$(grep -E '^Hugepagesize' /proc/meminfo | awk '{print $2}')
  HP_GB=$(( HP_TOTAL * HP_KB / 1024 / 1024 ))
  warn "pre-reserved hugepages detected: ${HP_TOTAL} pages (${HP_GB} GiB) -- this memory is unavailable to WEKA and the OS. WEKA's agent manages its OWN hugepages from the container memory sizing; verify the reservation is intentional and leaves room for the carve"
else
  ok "no conflicting pre-reserved hugepages (WEKA's agent manages its own)"
fi

# ---------- 8b. SELinux (RHEL-family: Rocky/Alma/RHEL ship enforcing) ----------
if command -v getenforce >/dev/null 2>&1; then
  SEL=$(getenforce 2>/dev/null || echo unknown)
  case "$SEL" in
    Enforcing) warn "SELinux is Enforcing -- set permissive for the first install run (setenforce 0 + SELINUX=permissive in /etc/selinux/config) to keep variables out; revisit enforcing after validation" ;;
    *) ok "SELinux: ${SEL}" ;;
  esac
fi

# ---------- 9. disk space for /opt/weka ----------
FREE=$(df -BG --output=avail "$( [ -d /opt ] && echo /opt || echo / )" | tail -1 | tr -dc '0-9')
[ "$FREE" -ge "$MIN_FREE_GB" ] && ok "free space on /opt fs: ${FREE} GiB >= ${MIN_FREE_GB}" \
                               || bad "only ${FREE} GiB free on /opt fs (need >= ${MIN_FREE_GB} for WEKA install)"

# ---------- 10. AWS service reachability ----------
if [ -n "${REGION:-}" ]; then
  for svc in s3 secretsmanager ssm; do
    # no -f: ANY http response (404 included) proves reachability; only
    # connection-level failures mean the endpoint is missing
    if curl -s -m 8 -o /dev/null "https://${svc}.${REGION}.amazonaws.com"; then
      ok "${svc}.${REGION}.amazonaws.com reachable"
    else
      # SSM is implicitly working if this runs via SSM; S3/secretsmanager need endpoint or NAT
      [ "$svc" = "ssm" ] && warn "ssm endpoint probe failed (ignore if this ran via SSM)" \
                         || bad "${svc}.${REGION}.amazonaws.com unreachable -- add a VPC endpoint or NAT (installer/day-2 needs it)"
    fi
  done
fi

# ---------- 11. leftover weka state ----------
if have weka && weka local ps 2>/dev/null | grep -qi drives0; then
  warn "existing weka cluster containers on this node -- day-0 cleanup phase will refuse; tear down first"
else
  ok "no conflicting weka containers"
fi

echo
echo "##### RESULT: ${PASS} pass / ${WARN} warn / ${FAIL} fail #####"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
