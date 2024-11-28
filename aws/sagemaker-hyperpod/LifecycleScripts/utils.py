import json
import os

INSTANCE_TYPE_TO_CORE_IDS = {
    "ml.p5.48xlarge": ['40', '41', '42', '43'],
    "ml.c5.4xlarge": ['3'],  # for testing
    "ml.c5.9xlarge": ['3', '4'],  # for testing
}

NICS_RANGES = {
    "ml.p5.48xlarge": [(72, 75), (88, 91), (105, 108), (122, 125)]
}


def get_ips_to_core_ids_map():
    config = json.load(open('/opt/ml/config/resource_config.json'))
    ip_to_core_ids = {}
    for group in config["InstanceGroups"]:
        instance_type = group["InstanceType"]
        for instance in group["Instances"]:
            ip_to_core_ids[instance["CustomerIpAddress"]] = INSTANCE_TYPE_TO_CORE_IDS.get(instance_type, [])

    return ip_to_core_ids


def get_nics(instance_type):
    with os.popen('ls /sys/class/net') as net_list:
        dfault_namespace_interfaces = net_list.read().splitlines()

    nics_ranges = NICS_RANGES.get(instance_type, [])
    nics = []
    for nics_range in nics_ranges:
        for index in range(nics_range[0], nics_range[1] + 1):
            nic_name = f'enp{index}s0'
            if nic_name not in dfault_namespace_interfaces:
                nics.append(nic_name)
                break

    return nics
