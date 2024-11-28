#!/usr/bin/python3

import re
import shutil
import argparse
import logging
from pathlib import Path
from typing import List, Tuple

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

SLURM_GLOBAL_PARAMS = {
    'ProctrackType': 'proctrack/cgroup',
    'TaskPlugin': 'task/affinity,task/cgroup',
    'TaskPluginParam': 'SlurmdOffSpec',
    'SelectType': 'select/cons_tres',
    'SelectTypeParameters': 'CR_Core_Memory',
    'JobAcctGatherType': 'jobacct_gather/group',
    'PrologFlags': 'Contain'
}

def modify_memory(line: str, reduction_size_gb: int, min_memory_gb: int) -> Tuple[str, bool]:
    """Reduce RealMemory if possible while maintaining minimum threshold."""
    REDUCTION_SIZE = reduction_size_gb * 1024
    MIN_MEMORY = min_memory_gb * 1024

    memory_match = re.search(r'RealMemory=(\d+)', line)
    node_match = re.search(r'NodeName=(\S+)', line)
    node_name = node_match.group(1) if node_match else "Unknown"

    if memory_match:
        current_memory = int(memory_match.group(1))
        if current_memory - REDUCTION_SIZE > MIN_MEMORY:
            new_memory = current_memory - REDUCTION_SIZE
            line = re.sub(r'RealMemory=\d+', f'RealMemory={new_memory}', line)
            return line, True
        else:
            logger.warning(f"Node {node_name}: Cannot reduce memory by {reduction_size_gb}GB while maintaining {min_memory_gb}GB minimum")
    return line, False

def get_reserved_cpus(total_cpus: int, sockets: int, reserve_count: int) -> List[int]:
    """Calculate CPU IDs to reserve based on socket configuration."""
    if sockets == 1:
        return list(range(total_cpus - reserve_count, total_cpus))

    if reserve_count % 2 != 0:
        raise ValueError("Must reserve even number of CPUs when using 2 sockets")

    cores_per_socket = total_cpus // 2
    per_socket_reserve = reserve_count // 2

    socket1_reserved = list(range(cores_per_socket - per_socket_reserve, cores_per_socket))
    socket2_reserved = list(range(total_cpus - per_socket_reserve, total_cpus))

    return socket1_reserved + socket2_reserved

def add_cpuspeclist(line: str, cpu_reserve_count: int) -> Tuple[str, bool]:
    """Add CpuSpecList parameter without modifying CPU counts."""
    socket_match = re.search(r'SocketsPerBoard=(\d+)', line)
    node_match = re.search(r'NodeName=(\S+)', line)
    node_name = node_match.group(1) if node_match else "Unknown"

    if not socket_match:
        logger.warning(f"Node {node_name}: Missing SocketsPerBoard parameter")
        return line, False

    sockets = int(socket_match.group(1))
    if sockets not in [1, 2]:
        logger.warning(f"Node {node_name}: Invalid SocketsPerBoard value: {sockets}")
        return line, False

    cpu_match = re.search(r'CPUs=(\d+)', line)
    if not cpu_match:
        logger.warning(f"Node {node_name}: Missing CPUs parameter")
        return line, False

    total_cpus = int(cpu_match.group(1))
    if cpu_reserve_count >= total_cpus:
        logger.warning(f"Node {node_name}: Cannot reserve {cpu_reserve_count} CPUs from node with only {total_cpus} CPUs")
        return line, False

    try:
        reserved_cpus = get_reserved_cpus(total_cpus, sockets, cpu_reserve_count)
        cpu_spec_list = ','.join(map(str, reserved_cpus))
        line = line.rstrip() + f' CpuSpecList={cpu_spec_list}\n'
        return line, True
    except Exception as e:
        logger.warning(f"Node {node_name}: Error adding CpuSpecList: {str(e)}")
        return line, False

def has_cpuspeclist(line: str) -> bool:
    """Check if node already has CpuSpecList parameter."""
    return 'CpuSpecList=' in line

def set_global_parameters(line: str) -> str:
    """Update or add global Slurm configuration parameters."""
    # Check if line starts with any of our target parameters
    for param, value in SLURM_GLOBAL_PARAMS.items():
        if line.strip().startswith(param + '='):
            return f"{param}={value}\n"

    return line


def modify_config_file(config_file: str, cpu_reserve_count: int, memory_reduction_gb: int, min_memory_gb: int) -> None:
    """Process and update the Slurm config file."""
    import subprocess

    temp_file = config_file + '.tmp'
    seen_params = set()
    scheduling_index = None

    with open(config_file, 'r') as f:
        lines = f.readlines()

    modified_lines = []
    for i, line in enumerate(lines):
        if line.strip() == '#SCHEDULING':
            scheduling_index = i

        if line.strip().startswith('NodeName=') and not has_cpuspeclist(line):
            memory_line, memory_modified = modify_memory(line, memory_reduction_gb, min_memory_gb)
            cpu_line, cpu_modified = add_cpuspeclist(memory_line, cpu_reserve_count)
            if not (memory_modified or cpu_modified):
                logger.warning(f"No modifications made to node configuration: {line.strip()}")
            line = cpu_line
        else:
            original_line = line
            line = set_global_parameters(line)
            if line != original_line:
                param_name = line.split('=')[0].strip()
                seen_params.add(param_name)

        modified_lines.append(line)

    if scheduling_index is not None:
        missing_params = []
        for param, value in SLURM_GLOBAL_PARAMS.items():
            if param not in seen_params:
                missing_params.append(f"{param}={value}\n")

        if missing_params:
            modified_lines[scheduling_index:scheduling_index] = [''] + missing_params + ['']
    else:
        logger.warning("Could not find #SCHEDULING section in config file")

    with open(temp_file, 'w') as f:
        f.writelines(modified_lines)

    shutil.move(temp_file, config_file)

    # Restart slurmctld service
    try:
        subprocess.run(['systemctl', 'restart', 'slurmctld.service'], check=True)
        logger.info("Successfully restarted slurmctld service")
    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to restart slurmctld service: {e}")
        raise


def main():
    parser = argparse.ArgumentParser(description='Modify Slurm configuration')
    parser.add_argument('--config', default='slurm.conf', help='Path to slurm.conf')
    parser.add_argument('--reserve-cpus', type=int, required=True, help='Number of CPUs to reserve')
    parser.add_argument('--reduce-memory', type=int, required=True, help='Amount of memory to reduce in GB')
    parser.add_argument('--min-memory', type=int, required=True, help='Minimum memory threshold in GB')

    args = parser.parse_args()

    try:
        modify_config_file(args.config, args.reserve_cpus, args.reduce_memory, args.min_memory)
        logger.info(f"Successfully modified {args.config}")
    except Exception as e:
        logger.error(f"Error processing file: {str(e)}")

if __name__ == "__main__":
    main()
