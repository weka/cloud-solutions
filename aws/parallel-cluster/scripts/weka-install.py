#!/opt/weka-temp-venv/bin/python

"""
Provision ENIs (optional, for DPDK) and mount a WEKA filesystem via a systemd template unit.

"""

import argparse
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Dict, List, Optional, Set, Tuple

# AMI dependency safety checks (fail fast)
try:
    import boto3  # type: ignore
except ImportError as e:
    raise SystemExit(
        f"Missing dependency: boto3 ({e}). "
        "Install boto3/botocore or use an AWS AMI that includes them."
    )

try:
    import requests  # type: ignore
except ImportError as e:
    raise SystemExit(
        f"Missing dependency: requests ({e}). "
        "Install requests or use an AWS AMI that includes it."
    )

from botocore.exceptions import ClientError


# --- config ---
SYSTEMD_TEMPLATE_UNIT_PATH = "/etc/systemd/system/weka-mount@.service"
ENV_DIR = "/etc/weka/mount.d"
MOUNT_SH_PATH = "/usr/local/bin/weka_mount.sh"
UMOUNT_SH_PATH = "/usr/local/bin/weka_umount.sh"


TEMPLATE_UNIT = f"""[Unit]
Description=WEKA Filesystem Mount Service (%i)
After=network-online.target remote-fs.target
Wants=network-online.target
Before=slurmd.service slurmctld.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart={MOUNT_SH_PATH} %i
ExecStop={UMOUNT_SH_PATH} %i
TimeoutStartSec=300
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target
"""

MOUNT_SH = f"""#!/bin/bash
set -euo pipefail

log() {{
  logger -t weka_mount "$1"
  echo "$1" >&2
}}

if [ $# -ne 1 ]; then
  log "Usage: $0 <fs_instance>"
  exit 1
fi

FS_INSTANCE="$1"
ENV_FILE="{ENV_DIR}/${{FS_INSTANCE}}.conf"

if [ ! -f "$ENV_FILE" ]; then
  log "Missing env file: $ENV_FILE"
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

req_vars=(ALB_HOST FS_NAME MOUNT_POINT MODE MGMT_IP)
for v in "${{req_vars[@]}}"; do
  if [ -z "${{!v:-}}" ]; then
    log "Missing $v in $ENV_FILE"
    exit 1
  fi
done

if mountpoint -q "$MOUNT_POINT"; then
  log "Already mounted: $MOUNT_POINT"
  exit 0
fi

mkdir -p "$MOUNT_POINT"

cmd=(mount -t wekafs "-o" "mgmt_ip=${{MGMT_IP}}")

if [ "$MODE" = "dpdk" ]; then
  if [ -z "${{DPDK_NETS:-}}" ] || [ -z "${{CORES:-}}" ]; then
    log "DPDK mode requires DPDK_NETS and CORES"
    exit 1
  fi
  for nic in $DPDK_NETS; do
    cmd+=("-o" "net=${{nic}}")
  done
  for core in $CORES; do
    cmd+=("-o" "core=${{core}}")
  done
else
  cmd+=("-o" "net=udp")
fi

cmd+=("${{ALB_HOST}}/${{FS_NAME}}" "${{MOUNT_POINT}}")

log "Executing: ${{cmd[*]}}"
"${{cmd[@]}}"

log "Mounted ${{ALB_HOST}}/${{FS_NAME}} at ${{MOUNT_POINT}}"
"""

UMOUNT_SH = f"""#!/bin/bash
set -euo pipefail

log() {{
  logger -t weka_umount "$1"
  echo "$1" >&2
}}

if [ $# -ne 1 ]; then
  log "Usage: $0 <fs_instance>"
  exit 1
fi

FS_INSTANCE="$1"
ENV_FILE="{ENV_DIR}/${{FS_INSTANCE}}.conf"

if [ ! -f "$ENV_FILE" ]; then
  log "Missing env file: $ENV_FILE"
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

if [ -z "${{MOUNT_POINT:-}}" ]; then
  log "Missing MOUNT_POINT in $ENV_FILE"
  exit 1
fi

if ! mountpoint -q "$MOUNT_POINT"; then
  log "Not mounted: $MOUNT_POINT"
  exit 0
fi

check_network() {{
  local host
  host="$(weka local ps 2>/dev/null | grep -oP 'host=\\K[^ ]+' | head -1 || true)"
  [ -n "$host" ] || return 1
  ping -c 1 "$host" >/dev/null 2>&1
}}

do_umount() {{
  local mp="$1"
  local force="$2"
  local opts=()
  [ "$force" = "force" ] && opts+=("-f")
  umount "${{opts[@]}}" "$mp"
}}

log "Unmounting $MOUNT_POINT"
if ! check_network; then
  log "Network down/WEKA unavailable -> force unmount"
  do_umount "$MOUNT_POINT" "force"
  exit $?
fi

if do_umount "$MOUNT_POINT" ""; then
  log "Unmounted cleanly: $MOUNT_POINT"
  exit 0
fi

log "Clean unmount failed -> force unmount"
do_umount "$MOUNT_POINT" "force"
"""


# --- logging ---
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
log = logging.getLogger("weka-mounter")


# --- helpers ---
def sh(cmd: List[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess:
    log.debug("cmd: %s", " ".join(cmd))
    return subprocess.run(cmd, check=check, text=True, capture_output=capture)


def write_file(path: str, content: str, mode: int) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)
    os.chmod(path, mode)


def ensure_root() -> None:
    if os.geteuid() != 0:
        raise SystemExit("Must run as root (writes systemd files/scripts and mounts).")


def sanitize_instance_name(s: str) -> str:
    if not s or not s.strip():
        raise ValueError("filesystem name is empty")
    if "/" in s:
        raise ValueError("filesystem name must not contain '/'")
    return re.sub(r"[^A-Za-z0-9._-]", "_", s.strip())


def parse_semver(s: str) -> Tuple[int, int, int]:
    s = s.strip().lstrip("vV")
    m = re.search(r"(\d+)(?:\.(\d+))?(?:\.(\d+))?", s)
    if not m:
        raise ValueError(f"Could not parse version: {s}")
    return (int(m.group(1)), int(m.group(2) or 0), int(m.group(3) or 0))


def ensure_weka_installed(alb_host: str, min_version: Optional[str]) -> None:
    want = parse_semver(min_version) if min_version else None

    def installed_version() -> Optional[Tuple[int, int, int]]:
        if not shutil.which("weka"):
            return None
        for cmd in (["weka", "version"], ["weka", "--version"]):
            cp = sh(cmd, check=False, capture=True)
            out = (cp.stdout or cp.stderr or "").strip()
            if cp.returncode == 0 and out:
                try:
                    return parse_semver(out)
                except Exception:
                    return None
        return None

    have = installed_version()
    if have and (want is None or have >= want):
        log.info("WEKA already installed (version=%s)", have)
        return

    url = f"https://{alb_host}:14000/dist/v1/install"
    log.info("Installing WEKA from %s", url)

    with tempfile.TemporaryDirectory(prefix="weka-install-") as td:
        script_path = os.path.join(td, "install_script.sh")
        sh(["curl", "--fail", "-k", "-L", "-o", script_path, url], check=True)
        sh(["chmod", "+x", script_path], check=True)
        sh([script_path], check=True)

    have2 = installed_version()
    if not have2:
        raise RuntimeError("WEKA install finished but `weka` is not working/found")
    if want and have2 < want:
        raise RuntimeError(f"Installed WEKA version {have2} is below required {want}")
    log.info("WEKA installed (version=%s)", have2)


# --- IMDS ---
class EC2MetadataClient:
    def __init__(self) -> None:
        self.base = "http://169.254.169.254/latest"  # HTTP only (IMDS)
        self.token = self._token()

    def _token(self) -> str:
        try:
            r = requests.put(
                f"{self.base}/api/token",
                headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"},
                timeout=2,
            )
            r.raise_for_status()
            return r.text
        except requests.RequestException as e:
            raise SystemExit(f"IMDS token error: {e}")

    def get(self, path: str) -> str:
        try:
            r = requests.get(
                f"{self.base}/meta-data/{path}",
                headers={"X-aws-ec2-metadata-token": self.token},
                timeout=2,
            )
            r.raise_for_status()
            return r.text
        except requests.RequestException as e:
            raise SystemExit(f"IMDS get error ({path}): {e}")


# --- ENI management ---
class EC2NetworkInterfaceManager:
    def __init__(self, imds: EC2MetadataClient):
        self.imds = imds
        self.instance_id = imds.get("instance-id").strip()
        self.region = imds.get("placement/availability-zone").strip()[:-1]

        self.ec2_client = boto3.client("ec2", region_name=self.region)
        self.ec2 = boto3.resource("ec2", region_name=self.region)

        self.instance_type = ""
        self.network_card_count = 1
        self.max_enis = 0
        self.subnet_id = ""

        self.refresh()

    def refresh(self) -> None:
        inst = self.ec2.Instance(self.instance_id)
        self.instance_type = inst.instance_type
        self.subnet_id = inst.subnet_id

        info = self.ec2_client.describe_instance_types(InstanceTypes=[self.instance_type])["InstanceTypes"][0]["NetworkInfo"]
        self.network_card_count = info.get("MaximumNetworkCards", 1)
        self.max_enis = info["MaximumNetworkInterfaces"]

        # trigger fetch of ENIs
        _ = inst.network_interfaces

        log.info(
            "Instance=%s type=%s cards=%d max_enis=%d current_enis=%d",
            self.instance_id,
            self.instance_type,
            self.network_card_count,
            self.max_enis,
            len(inst.network_interfaces),
        )

    def _used_pairs(self) -> Set[Tuple[int, int]]:
        used: Set[Tuple[int, int]] = set()
        resp = self.ec2_client.describe_network_interfaces(
            Filters=[{"Name": "attachment.instance-id", "Values": [self.instance_id]}]
        )
        for ni in resp["NetworkInterfaces"]:
            att = ni.get("Attachment")
            if not att:
                continue
            di = att.get("DeviceIndex")
            if di is None:
                continue
            ci = 0 if self.network_card_count == 1 else att.get("NetworkCardIndex", 0)
            used.add((di, ci))
        return used

    def _next_slot(self) -> Optional[Tuple[int, int]]:
        # policy: skip device index 0, iterate 1..max-1, spread across cards
        used = self._used_pairs()
        for device_index in range(1, self.max_enis):
            for card_index in range(self.network_card_count):
                if (device_index, card_index) not in used:
                    return (device_index, card_index)
        return None

    def _wait_eni_status(self, eni_id: str, want: str, attempts: int = 40, sleep_s: int = 3) -> None:
        for _ in range(attempts):
            resp = self.ec2_client.describe_network_interfaces(NetworkInterfaceIds=[eni_id])
            status = resp["NetworkInterfaces"][0]["Status"]
            if status == want:
                return
            time.sleep(sleep_s)
        raise RuntimeError(f"Timeout waiting for ENI {eni_id} to reach {want}")

    def create_enis(self, count: int, security_groups: Optional[List[str]]) -> List[str]:
        inst = self.ec2.Instance(self.instance_id)
        current = len(inst.network_interfaces)
        if current + count > self.max_enis:
            raise RuntimeError(f"ENI limit: current={current} + new={count} > max={self.max_enis}")

        created: List[str] = []
        run_id = int(time.time())
        try:
            for i in range(count):
                params: Dict = {
                    "SubnetId": self.subnet_id,
                    "Description": f"Weka DPDK ENI for {self.instance_id}",
                    "TagSpecifications": [{
                        "ResourceType": "network-interface",
                        "Tags": [
                            {"Key": "Name", "Value": f"weka-dpdk-{self.instance_id}-{run_id}-{i+1}"},
                            {"Key": "CreatedBy", "Value": "weka-mounter"},
                        ],
                    }],
                }
                if security_groups:
                    params["Groups"] = security_groups

                eni = self.ec2.create_network_interface(**params)
                created.append(eni.id)
                log.info("Created ENI %s", eni.id)
                self._wait_eni_status(eni.id, "available")
            return created
        except Exception:
            for eni_id in created:
                try:
                    self.ec2.NetworkInterface(eni_id).delete()
                    log.info("Deleted ENI %s (cleanup)", eni_id)
                except Exception:
                    pass
            raise

    def attach_enis(self, eni_ids: List[str]) -> None:
        attached: List[Tuple[str, str]] = []
        try:
            for eni_id in eni_ids:
                slot = self._next_slot()
                if not slot:
                    raise RuntimeError("No attachment slots available")
                di, ci = slot

                params: Dict = {"NetworkInterfaceId": eni_id, "InstanceId": self.instance_id, "DeviceIndex": di}
                if self.network_card_count > 1:
                    params["NetworkCardIndex"] = ci

                resp = self.ec2_client.attach_network_interface(**params)
                att_id = resp["AttachmentId"]
                attached.append((eni_id, att_id))

                self.ec2_client.modify_network_interface_attribute(
                    NetworkInterfaceId=eni_id,
                    Attachment={"AttachmentId": att_id, "DeleteOnTermination": True},
                )
                log.info("Attached ENI %s at device=%d card=%s", eni_id, di, ci if self.network_card_count > 1 else "N/A")

            self.refresh()
        except Exception:
            for eni_id, att_id in attached:
                try:
                    self.ec2_client.detach_network_interface(AttachmentId=att_id, Force=True)
                    log.info("Detached ENI %s (cleanup)", eni_id)
                except Exception:
                    pass
            raise


def resolve_eni_ifnames(imds: EC2MetadataClient, eni_ids: List[str], attempts: int = 40, sleep_s: int = 3) -> List[str]:
    eni_set = set(eni_ids)

    def ifname_for_mac(mac: str) -> Optional[str]:
        mac = mac.lower()
        for ifname in os.listdir("/sys/class/net"):
            if ifname == "lo" or ifname.startswith(("docker", "veth")):
                continue
            try:
                with open(f"/sys/class/net/{ifname}/address", "r") as f:
                    if f.read().strip().lower() == mac:
                        return ifname
            except FileNotFoundError:
                continue
        return None

    for attempt in range(1, attempts + 1):
        macs = imds.get("network/interfaces/macs/").strip().splitlines()
        macs = [m.strip("/").lower() for m in macs if m.strip()]

        eni_to_if: Dict[str, str] = {}
        for mac in macs:
            iface_id = imds.get(f"network/interfaces/macs/{mac}/interface-id").strip()
            if iface_id not in eni_set:
                continue
            ifname = ifname_for_mac(mac)
            if ifname:
                eni_to_if[iface_id] = ifname

        missing = eni_set - set(eni_to_if.keys())
        if not missing:
            return sorted(set(eni_to_if.values()))

        log.warning("Resolve ifnames attempt %d/%d missing ENIs=%s", attempt, attempts, sorted(missing))
        time.sleep(sleep_s)

    return []


# --- systemd management ---
class SystemdManager:
    def ensure_base(self) -> None:
        os.makedirs(ENV_DIR, exist_ok=True)
        write_file(MOUNT_SH_PATH, MOUNT_SH, 0o755)
        write_file(UMOUNT_SH_PATH, UMOUNT_SH, 0o755)

        if not os.path.exists(SYSTEMD_TEMPLATE_UNIT_PATH):
            write_file(SYSTEMD_TEMPLATE_UNIT_PATH, TEMPLATE_UNIT, 0o644)
            sh(["systemctl", "daemon-reload"], check=True)

    def _env_path(self, fs_instance: str) -> str:
        return os.path.join(ENV_DIR, f"{fs_instance}.conf")

    def _scan_mountpoints(self) -> Dict[str, str]:
        mp_to_fs: Dict[str, str] = {}
        if not os.path.isdir(ENV_DIR):
            return mp_to_fs
        for name in os.listdir(ENV_DIR):
            if not name.endswith(".conf"):
                continue
            fs = name[:-5]
            try:
                with open(os.path.join(ENV_DIR, name), "r") as f:
                    content = f.read()
                m = re.search(r'^MOUNT_POINT="?(.*?)"?$', content, flags=re.MULTILINE)
                if m:
                    mp_to_fs[m.group(1).strip()] = fs
            except Exception:
                pass
        return mp_to_fs

    def _mountpoint_active(self, mount_point: str) -> bool:
        return sh(["mountpoint", "-q", mount_point], check=False).returncode == 0

    def write_env(
        self,
        fs_instance: str,
        alb_host: str,
        fs_name: str,
        mount_point: str,
        mode: str,
        mgmt_ip: str,
        dpdk_nets: Optional[List[str]],
        cores: Optional[List[str]],
    ) -> str:
        # uniqueness: mount point cannot be used by another fs env
        existing = self._scan_mountpoints()
        owner = existing.get(mount_point)
        if owner and owner != fs_instance:
            raise RuntimeError(f"Mount point '{mount_point}' already assigned to filesystem '{owner}'")

        if self._mountpoint_active(mount_point):
            raise RuntimeError(f"Mount point '{mount_point}' is already mounted")

        lines: List[str] = [
            f'ALB_HOST="{alb_host}"',
            f'FS_NAME="{fs_name}"',
            f'MOUNT_POINT="{mount_point}"',
            f'MODE="{mode}"',
            f'MGMT_IP="{mgmt_ip}"',
        ]

        if mode == "dpdk":
            if not dpdk_nets or not cores:
                raise RuntimeError("DPDK mode requires resolved NICs and cores")
            lines.append(f'DPDK_NETS="{ " ".join(dpdk_nets) }"')
            lines.append(f'CORES="{ " ".join(cores) }"')
        else:
            lines.append('DPDK_NETS=""')
            lines.append('CORES=""')

        path = self._env_path(fs_instance)
        write_file(path, "\n".join(lines) + "\n", 0o600)
        return path

    def enable_now(self, fs_instance: str) -> str:
        unit = f"weka-mount@{fs_instance}.service"
        log.info("Enabling/starting: %s", unit)
        sh(["systemctl", "daemon-reload"], check=True)
        sh(["systemctl", "enable", "--now", unit], check=True)
        return unit


# --- args / main ---
def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Mount a WEKA filesystem (optional DPDK ENI provisioning).")
    p.add_argument("--alb-dns-name", required=True, help="ALB hostname only (no scheme/path)")
    p.add_argument("--filesystem-name", default="default", help="Filesystem name (also systemd instance)")
    p.add_argument("--mount-point", default="/mnt/weka", help="Mount point")
    p.add_argument("--cores", type=lambda x: x.split(","), help="Comma-separated CPU cores (DPDK mode; 1 core per NIC)")
    p.add_argument("--security-groups", type=lambda x: x.split(","), help="Comma-separated security group IDs for new ENIs")
    p.add_argument("--weka-min-version", default=None, help="Minimum WEKA version, e.g. 4.2.13")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"])
    return p.parse_args()


def main() -> None:
    args = parse_args()
    log.setLevel(getattr(logging, args.log_level))

    ensure_root()

    # Force HTTP usage by ensuring user provided a hostname only
    if "://" in args.alb_dns_name or "/" in args.alb_dns_name:
        raise ValueError("--alb-dns-name must be a hostname only (no scheme or path)")

    fs_instance = sanitize_instance_name(args.filesystem_name)
    mode = "dpdk" if args.cores else "udp"

    imds = EC2MetadataClient()
    mgmt_ip = imds.get("local-ipv4").strip()  # IMDS local-ipv4

    if args.dry_run:
        log.info("DRY RUN: filesystem=%s mode=%s mount=%s mgmt_ip=%s", fs_instance, mode, args.mount_point, mgmt_ip)
        if mode == "dpdk":
            log.info("DRY RUN: would create+attach %d ENIs (1 per core)", len(args.cores))
        log.info("DRY RUN: would write env and enable weka-mount@%s.service", fs_instance)
        return

    ensure_weka_installed(args.alb_dns_name, args.weka_min_version)

    dpdk_ifnames: Optional[List[str]] = None
    if mode == "dpdk":
        cores = args.cores or []
        eni = EC2NetworkInterfaceManager(imds)
        created = eni.create_enis(len(cores), args.security_groups)
        eni.attach_enis(created)

        dpdk_ifnames = resolve_eni_ifnames(imds, created)
        if len(dpdk_ifnames) != len(cores):
            raise RuntimeError(
                f"DPDK requires 1 NIC per core: cores={len(cores)} nics={len(dpdk_ifnames)} ({dpdk_ifnames})"
            )

    sd = SystemdManager()
    sd.ensure_base()

    env_path = sd.write_env(
        fs_instance=fs_instance,
        alb_host=args.alb_dns_name,
        fs_name=fs_instance,
        mount_point=args.mount_point,
        mode=mode,
        mgmt_ip=mgmt_ip,
        dpdk_nets=dpdk_ifnames,
        cores=args.cores,
    )
    unit = sd.enable_now(fs_instance)
    log.info("Done. unit=%s env=%s", unit, env_path)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log.error("Fatal: %s", e)
        sys.exit(1)

