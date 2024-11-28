#!/usr/bin/python3

import logging
import subprocess
import sys
from collections import OrderedDict
from weka.utils import get_ips_to_core_ids_map

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

SLURM_GLOBAL_PARAMS = {
    'ProctrackType': 'proctrack/cgroup',
    'TaskPlugin': 'task/affinity,task/cgroup',
    'TaskPluginParam': 'SlurmdOffSpec',
    'SelectType': 'select/cons_tres',
    'SelectTypeParameters': 'CR_Core_Memory',
    'JobAcctGatherType': 'jobacct_gather/cgroup',
    'PrologFlags': 'Contain'
}


def slurm_to_json(file_path: str) -> OrderedDict:
    config = OrderedDict()
    count = 0
    with open(file_path, 'r') as f:
        for line in f.readlines():
            line = line.strip()

            if line.startswith("#") or not line:
                config[f'placeholder_{count}'] = line
                count += 1
                continue

            if line.startswith("Include "):
                if 'Include' not in config:
                    config['Include'] = [line.split(' ')[1]]
                else:
                    config['Include'].append(line.split(' ')[1])
                continue

            parts = line.split(' ')
            if len(parts) > 1 and len(line.split("=")) > 2:
                key = parts[0].split('=')[0]
                if key not in config:
                    config[key] = []

                value = OrderedDict()
                for part in parts:
                    subparts = part.split('=')
                    value[subparts[0]] = subparts[1]
                config[key].append(value)
            else:
                parts = line.split('=')
                config[parts[0]] = parts[1]

    return config


def json_to_slurm(config: dict) -> str:
    result = ''
    for key, value in config.items():
        if key.startswith('placeholder_'):
            result += f'{value}\n'
        elif key == 'Include':
            for include in value:
                result += f'Include {include}\n'
        elif isinstance(value, list):
            for line_dict in value:
                line = ''
                for subkey, subvalue in line_dict.items():
                    line += f"{subkey}={subvalue} "
                result += line[: -1] + '\n'
        else:
            result += f"{key}={value}\n"

    return result.strip()


def modify_memory(node_name: str, current_memory: int, reduction_size_gb: int, min_memory_gb: int) -> int:
    """Reduce RealMemory if possible while maintaining minimum threshold."""
    reduction_size = reduction_size_gb * 1024
    min_memory = min_memory_gb * 1024

    if current_memory - reduction_size > min_memory:
        return current_memory - reduction_size
    else:
        logger.warning(
            f"Node {node_name}: Cannot reduce memory by {reduction_size_gb}GB while maintaining {min_memory_gb}GB minimum")
        return current_memory


def modify_config_file(config_file: str, memory_reduction_gb: int, min_memory_gb: int) -> None:
    """Process and update the Slurm config file."""

    config = slurm_to_json(config_file)
    edit_required = False
    if 'placeholder_weka_additional_params' not in config:
        edit_required = True
        config[f'placeholder_weka_additional_params'] = '\n# Additional configurations for WEKA'
        for key, value in SLURM_GLOBAL_PARAMS.items():
            config[key] = value

    for node in config.get('NodeName', []):
        if not node.get('CpuSpecList'):
            edit_required = True
            node['RealMemory'] = modify_memory(node["NodeName"], int(node['RealMemory']), memory_reduction_gb, min_memory_gb)
            cpu_spec_list = get_ips_to_core_ids_map().get(node["NodeAddr"], [])
            node['CpuSpecList'] = ','.join(cpu_spec_list)

    if not edit_required:
        return

    config_str = json_to_slurm(config)
    with open(config_file, 'w') as f:
        f.write(config_str)

    # Restart slurmctld service
    try:
        subprocess.run(['systemctl', 'restart', 'slurmctld.service'], check=True)
        logger.info("Successfully restarted slurmctld service")
    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to restart slurmctld service: {e}")
        raise


if __name__ == "__main__":
    if len(sys.argv) < 2:
        logger.error("Please provide the path to the Slurm configuration file")
        sys.exit(1)

    modify_config_file(sys.argv[1], 5, 10)
