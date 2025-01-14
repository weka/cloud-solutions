#!/tmp/miniconda/envs/weka-temp-venv/bin/python

import boto3
import sys
import requests
import time
import argparse
import subprocess
import psutil
import socket
import os
import logging
from typing import Dict, List, Optional, Set, Tuple
from botocore.exceptions import ClientError


logger = logging.getLogger(__name__)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)


class EC2MetadataClient:
    """Client for accessing EC2 instance metadata."""

    def __init__(self):
        self.token = None
        self.metadata_url = "http://169.254.169.254/latest"
        self.token_url = f"{self.metadata_url}/api/token"
        self.get_token()

    def get_token(self) -> None:
        """Get IMDSv2 token."""
        headers = {
            'X-aws-ec2-metadata-token-ttl-seconds': '21600'
        }
        try:
            response = requests.put(self.token_url, headers=headers, timeout=2)
            self.token = response.text
        except requests.RequestException as e:
            logger.error(f"Error getting IMDSv2 token: {e}")
            sys.exit(1)

    def get_metadata(self, path: str) -> str:
        """Get metadata from specified path."""
        headers = {
            'X-aws-ec2-metadata-token': self.token
        }
        try:
            response = requests.get(
                f"{self.metadata_url}/meta-data/{path}",
                headers=headers,
                timeout=2
            )
            return response.text
        except requests.RequestException as e:
            logger.error(f"Error getting metadata from path {path}: {e}")
            sys.exit(1)


class EC2NetworkInterfaceManager:
    """Handles the creation and attachment of network interfaces."""

    def __init__(self):
        """ Initialize using instance metadata."""
        self.metadata_client = EC2MetadataClient()
        self.region = self.get_region()
        self.instance_id = self.metadata_client.get_metadata('instance-id')

        self.ec2_client = boto3.client('ec2', region_name=self.region)
        self.ec2 = boto3.resource('ec2', region_name=self.region)

        # Get instance info at initialization
        self.instance_info = self.get_instance_info()
        self.network_card_count = self.get_network_card_count(self.instance_info['instance_type'])

    def get_region(self) -> str:
        """Get region from instance metadata."""
        az = self.metadata_client.get_metadata('placement/availability-zone')
        return az[:-1]

    def get_instance_info(self) -> Dict:
        """ Get instance information including current ENIs and instance type."""
        try:
            instance = self.ec2.Instance(self.instance_id)
            return {
                'instance_type': instance.instance_type,
                'network_interfaces': instance.network_interfaces,
                'subnet_id': instance.subnet_id,
                'vpc_id': instance.vpc_id,
                'availability_zone': instance.placement['AvailabilityZone']
            }
        except ClientError as e:
            logger.error(f"Error getting instance info: {e}")
            sys.exit(1)

    def get_network_card_count(self, instance_type: str) -> int:
        """Get the number of network cards supported by the instance type."""
        try:
            response = self.ec2_client.describe_instance_types(
                InstanceTypes=[instance_type]
            )
            network_info = response['InstanceTypes'][0]['NetworkInfo']
            # Some instance types might not have NetworkCards defined
            # In that case, assume 1 network card
            return network_info.get('MaximumNetworkCards', 1)
        except ClientError as e:
            logger.error(f"Error getting instance network card info: {e}")
            sys.exit(1)

    def get_max_enis(self, instance_type: str) -> int:
        """Get the maximum number of ENIs allowed for an instance type."""
        try:
            response = self.ec2_client.describe_instance_types(
                InstanceTypes=[instance_type]
            )
            return response['InstanceTypes'][0]['NetworkInfo']['MaximumNetworkInterfaces']
        except ClientError as e:
            logger.error(f"Error getting instance type info: {e}")
            sys.exit(1)

    def get_used_device_card_pairs(self) -> Set[Tuple[int, int]]:
        """Get currently used device index and card index pairs."""
        used_pairs = set()

        try:
            # Get detailed information about network interfaces
            response = self.ec2_client.describe_network_interfaces(
                Filters=[
                    {
                        'Name': 'attachment.instance-id',
                        'Values': [self.instance_id]
                    }
                ]
            )

            for interface in response['NetworkInterfaces']:
                if 'Attachment' in interface:
                    attachment = interface['Attachment']
                    device_index = attachment.get('DeviceIndex')

                    # For instances with one network card, assume card index 0
                    if self.network_card_count == 1:
                        card_index = 0
                    else:
                        # For multi-card instances, get the card index from the attachment
                        # If not specified, assume it's on card 0
                        card_index = attachment.get('NetworkCardIndex', 0)

                    if device_index is not None:
                        used_pairs.add((device_index, card_index))
                        logger.info(f"Found existing ENI {interface['NetworkInterfaceId']} at "
                              f"Device Index {device_index}, Card Index {card_index}")

            return used_pairs

        except ClientError as e:
            logger.error(f"Error getting network interface information: {e}")
            sys.exit(1)

    def get_next_available_index_pair(self) -> Optional[Tuple[int, int]]:
        """Get the next available device index and card index pair."""
        used_pairs = self.get_used_device_card_pairs()
        logger.debug(f"\nCurrent used pairs: {used_pairs}")

        # For each network card
        for card_index in range(self.network_card_count):
            # Try device indices 0 and 1 for each card
            for device_index in range(2):
                if (device_index, card_index) not in used_pairs:
                    logger.info(f"Found available slot: Device Index {device_index}, Card Index {card_index}")
                    return (device_index, card_index)

        return None

    def wait_for_eni_available(self, eni_id: str, max_attempts: int = 40) -> bool:
        """Wait for an ENI to become available."""
        for attempt in range(max_attempts):
            try:
                response = self.ec2_client.describe_network_interfaces(
                    NetworkInterfaceIds=[eni_id]
                )
                status = response['NetworkInterfaces'][0]['Status']
                if status == 'available':
                    return True
                logger.debug(f"Waiting for ENI {eni_id} to become available (attempt {attempt + 1}/{max_attempts})")
                time.sleep(3)  # Wait 3 seconds between checks
            except ClientError as e:
                logger.error(f"Error checking ENI status: {e}")
                return False
        return False

    def create_network_interfaces(self,
                                num_interfaces: int,
                                security_group_ids: Optional[List[str]] = None) -> List[str]:
        """Create additional network interfaces to attach to EC2 instances."""
        max_enis = self.get_max_enis(self.instance_info['instance_type'])
        current_enis = len(self.instance_info['network_interfaces'])

        if current_enis + num_interfaces > max_enis:
            logger.error(
                f"Cannot add {num_interfaces} ENIs. Maximum allowed: {max_enis}, Current: {current_enis}"
            )
            sys.exit(1)

        created_enis = []
        try:
            for i in range(num_interfaces):
                # Create ENI
                network_interface_params = {
                    'SubnetId': self.instance_info['subnet_id'],
                    'Description': f'Additional ENI for {self.instance_id}',
                    'TagSpecifications': [{
                        'ResourceType': 'network-interface',
                        'Tags': [
                            {
                                'Key': 'Name',
                                'Value': f'weka-dpdk-interface-{i+1}'
                            }
                        ]
                    }]
                }

                if security_group_ids:
                    network_interface_params['Groups'] = security_group_ids

                eni = self.ec2.create_network_interface(**network_interface_params)
                created_enis.append(eni.id)
                logger.info(f"Created ENI {eni.id}")

                if not self.wait_for_eni_available(eni.id):
                    raise Exception(f"Timeout waiting for ENI {eni.id} to become available")

            return created_enis

        except Exception as e:
            logger.error(f"Error creating network interfaces: {e}")
            # Cleanup any created ENIs
            for eni_id in created_enis:
                try:
                    eni = self.ec2.NetworkInterface(eni_id)
                    eni.delete()
                    logger.info(f"Cleaned up ENI {eni_id}")
                except ClientError as cleanup_error:
                    logger.error(f"Error cleaning up ENI {eni_id}: {cleanup_error}")
            sys.exit(1)

    def attach_network_interfaces(self, eni_ids: List[str]) -> None:
        """Attach created network interfaces to the instance."""
        try:
            for eni_id in eni_ids:
                # Get next available index pair
                index_pair = self.get_next_available_index_pair()
                if not index_pair:
                    raise Exception("No available device and card index combinations")

                device_index, card_index = index_pair

                # For instances with only one network card, don't specify NetworkCardIndex
                attachment_params = {
                    'NetworkInterfaceId': eni_id,
                    'InstanceId': self.instance_id,
                    'DeviceIndex': device_index
                }

                # Only include NetworkCardIndex if instance has multiple network cards
                if self.network_card_count > 1:
                    attachment_params['NetworkCardIndex'] = card_index

                # Attach ENI
                attachment = self.ec2_client.attach_network_interface(**attachment_params)

                # Modify attribute to ensure deletion on detachment
                self.ec2_client.modify_network_interface_attribute(
                    NetworkInterfaceId=eni_id,
                    Attachment={
                        'AttachmentId': attachment['AttachmentId'],
                        'DeleteOnTermination': True
                    }
                )

                logger.info(
                    f"Attached ENI {eni_id} (Device Index: {device_index}, "
                    f"Card Index: {card_index if self.network_card_count > 1 else 'N/A'})"
                )
        except Exception as e:
            logger.error(f"Error attaching nework interfaces: {e}")
            raise

class WekaMount:
    """Handles WEKA filesystem mounting for both DPDK and UDP."""

    def __init__(self, metadata_client: EC2MetadataClient):
        self.metadata_client = metadata_client
        self.instance_type = self.metadata_client.get_metadata('instance-type')

    def get_interface_names(self, eni_ids: List[str]) -> List[str]:
        """Get interface names from ENI IDs by matching MAC addresses."""
        interface_names = []
        mac_addresses = {}
        max_attempts = 30  # Maximum number of attempts
        attempt = 0
        wait_time = 5  # Seconds to wait between attempts

        while attempt < max_attempts:
            attempt += 1
            # Get all network interfaces from metadata
            macs_text = self.metadata_client.get_metadata('network/interfaces/macs/')
            mac_list = [mac.strip('/') for mac in macs_text.split('\n')]

            logger.debug(f"Attempt {attempt}: Found MAC addresses from metadata: {mac_list}")

            # Build mapping of ENI ID to MAC address
            current_mac_addresses = {}
            for mac in mac_list:
                interface_id = self.metadata_client.get_metadata(f'network/interfaces/macs/{mac}/interface-id')
                if interface_id in eni_ids:
                    current_mac_addresses[mac.lower()] = interface_id
                    logger.debug(f"Added mapping: MAC {mac.lower()} -> ENI {interface_id}")

            # Check if we found all ENIs
            found_enis = set(current_mac_addresses.values())
            if all(eni in found_enis for eni in eni_ids):
                logger.info("Found all expected ENIs in metadata")
                mac_addresses = current_mac_addresses
                break
            else:
                missing_enis = set(eni_ids) - found_enis
                logger.warning(f"Missing ENIs in metadata: {missing_enis}")
                if attempt < max_attempts:
                    logger.info(f"Waiting {wait_time} seconds before retry...")
                    time.sleep(wait_time)
                else:
                    logger.warning("Maximum attempts reached, proceeding with available interfaces")
                    mac_addresses = current_mac_addresses

        logger.debug(f"Final MAC to ENI mapping: {mac_addresses}")

        try:
            # Get all network interfaces using psutil
            network_stats = psutil.net_if_addrs()

            for interface_name, addrs in network_stats.items():
                # Skip loopback and virtual interfaces
                if interface_name == 'lo' or interface_name.startswith(('docker', 'veth')):
                    continue

                # Look for MAC address in the interface addresses
                for addr in addrs:
                    if addr.family == psutil.AF_LINK:  # This is the MAC address
                        mac = addr.address.lower()
                        if mac in mac_addresses:
                            eni_id = mac_addresses[mac]
                            interface_names.append(interface_name)
                            logger.info(f"Found match: interface {interface_name} with MAC {mac} for ENI {eni_id}")
                            break

        except Exception as e:
            logger.error(f"Error getting network interfaces using psutil: {e}")
            return []

        return sorted(interface_names)  # Sort to ensure consistent ordering

    def get_management_interface_ip(self) -> str:
        """Get the first non-virtual management interface IP address using psutil."""
        try:
            # Get all network interfaces and their addresses
            net_if_addrs = psutil.net_if_addrs()

            # Sort interface names to ensure consistent selection
            interface_names = sorted(net_if_addrs.keys())

            for interface in interface_names:
                # Skip loopback and virtual interfaces
                if interface == 'lo' or interface.startswith(('docker', 'veth')):
                    continue

                # Get addresses for this interface
                addresses = net_if_addrs[interface]

                # Look for IPv4 address
                for addr in addresses:
                    # socket.AF_INET represents IPv4 addresses
                    if addr.family == socket.AF_INET:
                        logger.debug(f"Found management interface: {interface} with IP: {addr.address}")
                        return addr.address

            raise Exception("No suitable management interface found")

        except Exception as e:
            logger.error(f"Error getting management interface IP: {e}")
            raise

    def create_mount_script(self) -> None:
        """Create the WEKA mount script."""
        mount_script_content = '''#!/bin/bash

# Log function for debugging
log() {
    logger -t weka_mount "$1"
    echo "$1" >&2
}

if [ $# -lt 3 ]; then
    log "Error: Required parameters missing"
    log "Usage: $0 <mount_point> <alb_dns_name> <mode> [dpdk_options]"
    exit 1
fi

MOUNT_POINT="$1"
ALB_DNS_NAME="$2"
MODE="$3"
shift 3
DPDK_OPTIONS="$@"

# Check if already mounted
if mountpoint -q "$MOUNT_POINT"; then
    log "WEKA filesystem already mounted at $MOUNT_POINT"
    exit 0
fi

# Get management IP
MGMT_IP=$(ip -o -4 addr show | grep -v ' lo ' | head -1 | awk '{print $4}' | cut -d'/' -f1)

# Build mount command
MOUNT_CMD="mount -t wekafs -o mgmt_ip=${MGMT_IP}"

if [ "$MODE" = "dpdk" ]; then
    # Add DPDK-specific options
    MOUNT_CMD="$MOUNT_CMD $DPDK_OPTIONS"
else
    MOUNT_CMD="$MOUNT_CMD -o net=udp"
fi

# Add filesystem path and mount point
MOUNT_CMD="$MOUNT_CMD ${ALB_DNS_NAME}/default ${MOUNT_POINT}"

# Create mount point if it doesn't exist
mkdir -p "$MOUNT_POINT"

# Attempt mount
log "Executing: $MOUNT_CMD"
if eval "$MOUNT_CMD"; then
    log "Successfully mounted WEKA filesystem at $MOUNT_POINT"
    exit 0
else
    log "Failed to mount WEKA filesystem"
    exit 1
fi'''

        mount_script_path = '/usr/local/bin/weka_mount.sh'
        with open(mount_script_path, 'w') as f:
            f.write(mount_script_content)
        os.chmod(mount_script_path, 0o755)
        logger.info(f"Created mount script at {mount_script_path}")

    def create_unmount_script(self) -> None:
        """Create the WEKA unmount script."""
        unmount_script_content = '''#!/bin/bash

# Log function for debugging
log() {
    logger -t weka_umount "$1"
    echo "$1" >&2
}

# Function to check if network is available
check_network() {
    ping -c 1 $(weka local ps 2>/dev/null | grep -oP 'host=\\K[^ ]+' | head -1) >/dev/null 2>&1
}

# Function to handle unmounting with optional force
do_umount() {
    local mount_point="$1"
    local force="$2"
    local opts=""
    [[ "$force" == "force" ]] && opts="-f"

    if umount $opts "$mount_point"; then
        log "Successfully unmounted $mount_point${force:+ (force)}"
        return 0
    fi
    return 1
}

# Validate input
if [ $# -ne 1 ]; then
    log "Error: Mount point parameter is required"
    log "Usage: $0 <mount_point>"
    exit 1
fi

MOUNT_POINT="$1"

# Determine unmount strategy based on network availability
log "Attempting to unmount Weka filesystem at $MOUNT_POINT"
if ! check_network; then
    log "Network down, will use force unmount"
    do_umount "$MOUNT_POINT" "force" || exit 1
else
    log "Network available, attempting clean unmount"
    if ! do_umount "$MOUNT_POINT"; then
        log "Clean unmount failed, attempting force unmount..."
        do_umount "$MOUNT_POINT" "force" || exit 1
    fi
fi

exit 0'''

        unmount_script_path = '/usr/local/bin/weka_umount.sh'
        with open(unmount_script_path, 'w') as f:
            f.write(unmount_script_content)
        os.chmod(unmount_script_path, 0o755)
        logger.info(f"Created unmount script at {unmount_script_path}")

    def create_systemd_service(self,
                             mount_point: str,
                             alb_dns_name: str,
                             mount_mode: str,
                             interface_names: Optional[List[str]] = None,
                             cores: Optional[List[str]] = None) -> None:
        """Create and enable the WEKA systemd service."""
        # Build ExecStart command directly
        exec_start = f'/usr/local/bin/weka_mount.sh {mount_point} {alb_dns_name} {mount_mode}'

        # Add DPDK options directly to ExecStart command
        if mount_mode == 'dpdk' and interface_names and cores:
            for nic in interface_names:
                exec_start += f' -o net={nic}'
            for core in cores:
                exec_start += f' -o core={core}'

        service_content = f'''[Unit]
Description=WEKA Filesystem Mount Service
After=network-online.target remote-fs.target
Wants=network-online.target
Before=slurmd.service slurmctld.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart={exec_start}
ExecStop=/usr/local/bin/weka_umount.sh {mount_point}
TimeoutStartSec=300
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target'''

        service_path = '/etc/systemd/system/weka-mount.service'
        with open(service_path, 'w') as f:
            f.write(service_content)
        logger.info(f"Created systemd service at {service_path}")

        # Reload systemd and enable service
        subprocess.run(['systemctl', 'daemon-reload'], check=True)
        subprocess.run(['systemctl', 'enable', 'weka-mount'], check=True)
        subprocess.run(['systemctl', 'start', 'weka-mount'], check=True)
        logger.info("Enabled and started weka-mount service")

    def mount_filesystem(self,
                        alb_dns_name: str,
                        installation_path: str,
                        filesystem_name: str,
                        mount_point: str,
                        mount_mode: str,
                        interface_names: Optional[List[str]] = None,
                        cores: Optional[List[str]] = None) -> None:
        """Mount WEKA filesystem."""
        try:
            # Create installation directory
            os.makedirs(installation_path, exist_ok=True)
            os.chdir(installation_path)

            # Download and run installation script
            logger.info("Installing WEKA agent...")
            subprocess.run(['curl', '--fail', '-o', 'install_script.sh',
                           f'{alb_dns_name}:14000/dist/v1/install'], check=True)
            subprocess.run(['chmod', '+x', 'install_script.sh'], check=True)
            subprocess.run(['./install_script.sh'], check=True)

            # Update cgroups to not interfere with Slurm
            if mount_mode == 'dpdk':
                logger.info("Configuring cgroups and isolate_cpusets")
                subprocess.run(['chmod', '-R', '755', '/opt/weka/data/agent/tmpfss/cgroup'], check=True)
                subprocess.run(['sed', '-i', 's/isolate_cpusets=true/isolate_cpusets=false/g',
                               '/etc/wekaio/service.conf'], check=True)
                subprocess.run(['systemctl', 'restart', 'weka-agent'], check=True)

            # Create mount and unmount scripts
            self.create_mount_script()
            self.create_unmount_script()

            # Create and enable systemd service
            self.create_systemd_service(
                mount_point,
                alb_dns_name,
                mount_mode,
                interface_names,
                cores
            )

            # Cleanup
            subprocess.run(['rm', '-rf', installation_path], check=True)

        except subprocess.CalledProcessError as e:
            logger.error(f"Command execution failed: {e.cmd}")
            logger.error(f"Return code: {e.returncode}")
            if e.output:
                logger.error(f"Output: {e.output}")
            sys.exit(1)
        except Exception as e:
            logger.error(f"Error mounting filesystem: {e}")
            sys.exit(1)

def parse_args():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(
        description='Mount WEKA filesystem in either DPDK or UDP mode based on core specification.',
    )

    parser.add_argument(
        '--alb-dns-name',
        type=str,
        required=True,
        metavar='IP',
        help='DNS Name of WEKA ALB'
    )
    parser.add_argument(
        '--filesystem-name',
        type=str,
        default='default',
        metavar='NAME',
        help='WEKA filesystem name'
    )
    parser.add_argument(
        '--mount-point',
        type=str,
        default='/mnt/weka',
        metavar='PATH',
        help='Filesystem mount point'
    )
    parser.add_argument(
        '--cores',
        type=lambda x: x.split(','),
        metavar='CORE1,CORE2,...',
        help='CPU cores to use'
    )
    parser.add_argument(
        '--security-groups',
        type=lambda x: x.split(','),
        metavar='SG1,SG2,...',
        help='Security group IDs for network interfaces'
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Show what would be done without making changes'
    )
    parser.add_argument(
        '--log-level',
        type=str,
        choices=['DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'],
        default='INFO',
        help='Set logging level'
    )

    return parser.parse_args()

def main():
    """Main function to create ENIs and mount WEKA filesystem."""
    args = parse_args()

    # Set logging level
    logging.getLogger().setLevel(getattr(logging, args.log_level))

    # Initialize clients
    metadata_client = EC2MetadataClient()

    if args.dry_run:
        logger.info("DRY RUN - no changes will be made")
        sys.exit(0)

    try:
        created_enis = []
        interface_names = []
        installation_path = '/tmp/weka'

        if args.cores:  # DPDK mode
            # Initialize EC2 network manager for DPDK mode
            network_manager = EC2NetworkInterfaceManager()

            # Calculate number of interfaces based on number of cores
            num_interfaces = len(args.cores)

            logger.info(f"Instance ID: {network_manager.instance_id}")
            logger.info(f"Region: {network_manager.region}")
            logger.info(f"Instance type: {network_manager.instance_info['instance_type']}")
            logger.info(f"Number of network cards: {network_manager.network_card_count}")
            logger.info(f"Current ENIs: {len(network_manager.instance_info['network_interfaces'])}")
            logger.info(f"Maximum ENIs allowed: {network_manager.get_max_enis(network_manager.instance_info['instance_type'])}")
            logger.info(f"Required new ENIs (based on core count): {num_interfaces}")

            # Create and attach ENIs
            created_enis = network_manager.create_network_interfaces(
                num_interfaces,
                security_group_ids=args.security_groups
            )
            logger.info(f"Successfully created {len(created_enis)} ENIs: {created_enis}")

            # Attach network interfaces
            network_manager.attach_network_interfaces(created_enis)
            logger.info(f"Successfully attached {len(created_enis)} ENIs to instance {network_manager.instance_id}")

            # Get interface names for the created ENIs
            weka_mount = WekaMount(metadata_client)
            interface_names = weka_mount.get_interface_names(created_enis)
            logger.info(f"Corresponding interface names: {interface_names}")

        else:
            logger.info("No cores specified - using UDP mode")
            weka_mount = WekaMount(metadata_client)

        # Mount WEKA filesystem
        weka_mount.mount_filesystem(
            args.alb_dns_name,
            installation_path,
            args.filesystem_name,
            args.mount_point,
            'dpdk' if args.cores else 'udp',
            interface_names if args.cores else None,
            args.cores
        )

    except Exception as e:
        logger.error(f"Error in main execution: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
