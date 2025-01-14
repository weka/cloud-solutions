# WEKA and AWS ParallelCluster Integration

This repository provides scripts and configuration examples for integrating a [WEKA](https://weka.io) filesystem with AWS ParallelCluster. This is a proof of concept implementation that demonstrates how to mount WEKA filesystems on ParallelCluster nodes in both UDP and DPDK modes.

## Overview

The integration supports:
- UDP mode mounting for head nodes and basic compute needs
- DPDK mode for high-performance compute nodes
- Automatic ENI creation and configuration for DPDK mode
- Systemd service management for filesystem mounting and unmounting

## Prerequisites

Before using these integration scripts, ensure you have:

- An existing WEKA filesystem deployed in your AWS environment ([WEKA Documentation](https://docs.weka.io/planning-and-installation/aws/weka-installation-on-aws-using-terraform))
- DNS name of the Application Load Balancer associated with the WEKA cluster 
- Appropriate AWS IAM permissions (see example policies in repository)
- S3 bucket for storing integration scripts
- [AWS ParallelCluster CLI](https://docs.aws.amazon.com/parallelcluster/latest/ug/install-v3-parallelcluster.html) installed on your local machine (or wherever you will deploy ParallelCluster from). **Version 3.7.0 or higher is required**.

You will need to have an existing VPC with subnets configured, as well. How you configure that depends on your specific needs. The examples provided here make use of the default ParallelCluster configuration of using a small, public subnet for the head node and private subnet for the compute nodes. Note that if you decided to use EC2 instances that have more than 1 network device (e.g. `hpc7a`, `p4d`, `p5` instances) then they must be placed in a private subnet.
For more information on different network configurations that can be used, please see the [AWS ParallelCluster documentation](https://docs.aws.amazon.com/parallelcluster/latest/ug/network-configuration-v3.html)

## Repository Contents

- `weka-install.py`: Main installation script that handles WEKA filesystem configuration and mounting
- `virtualenv-setup.sh`: Sets up a Python virtual environment to assist with the WEKA installation process
- `example-pcluster-template.yaml`: Example ParallelCluster template with WEKA integration
- `example-pcluster-policy.json`: Example IAM policy for required AWS permissions

## Quick Start

1. Clone this repository and `cd` to the `aws/parallelcluster/` directory:
```bash
git clone https://github.com/weka/cloud-solutions.git
cd cloud-solutions/aws/parallelcluster
```

2. Upload the scripts to your S3 bucket:
```bash
aws s3 cp ./scripts/weka-install.py s3://YOUR-BUCKET/path/to/script
aws s3 cp ./scripts/virtualenv-setup.sh s3://YOUR-BUCKET/path/to/script
```

2. Create an IAM policy using `example-pcluster-policy.json` as a template. This policy will be attached to the head node and compute nodes to allow for mounting and accessing the WEKA filesystem

3. Modify the example ParallelCluster template for your environment:
   - Update S3 bucket references
   - Set your subnet IDs and security groups
   - Configure WEKA backend IP/DNS
   - Adjust instance types and computing resources as needed

4. Create your cluster using the modified template
```bash
pcluster create-cluster -c your-modified-template.yaml --cluster-name your-cluster-name --rollback-on-failure FALSE
```
Disabling the `rollback-on-failure` will help with debugging in case of errors during deployment.

## Understanding Key Components
### Security Configuration
The WEKA integration requires specific permissions and security configurations to operate properly. Also, any nodes mounting the WEKA filesyste need some permissions to interact with the WEKA cluster. Specifically, the permissions needed are:

- Ceate, attach, modify and delete ENIs
- Describe EC2 instances
- Cloudwatch logging
- Describe autoscaling groups

These permissions are defined in the provided example-pcluster-policy.json template.

An AWS security group is also required to allow resources to access the WEKA fileystem. The [WEKA Terraform module](https://registry.terraform.io/modules/weka/weka/aws/latest?tab=inputs) can automatically build this security group as part of the deployment, or users can create their own. We recommend that a self-referencing security allowing all traffic be used, but users can create a security group with specific ingress and egress rules based on [WEKA's required ports](https://docs.weka.io/planning-and-installation/prerequisites-and-compatibility#required-ports). Note that simialar rules need to be created for both TCP and UDP traffic.

However this security group is created it needs to be attached to all ParallelCluster nodes that will access the WEKA cluster. You can attach security groups using the `AddtionalSecurityGroup` sections of the head node as well as compute node:
```yaml
    Networking:
      AdditionalSecurityGroups:
      - sg-123456789abcdefg
```

### Network Interface Configuration
WEKA can provide several protocols for accessing the fileystem (e.g. NFS, S3, SMB), but the best performance is gained via the POSIX client that is installed. It makes use of [DPDK](https://www.dpdk.org) to enhance network performance by using a kernel bypass mechanism.
DPDK mode requires dedicated network interfaces in AWS, which is done by creating and attaching an [Elastic Network Interface](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-eni.html).

Each instance type and size in AWS has a maximum nubmer of network interfaces that can be attached to it (see [AWS documentation](https://docs.aws.amazon.com/ec2/latest/instancetypes/ec2-instance-type-specifications.html) for a complete list). Additionally, some instance types have multiple [network cards](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-eni.html#network-cards), allowing for increase performance. 

For instances that support [EFA](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html), ParallelCluster can automaically configure EFA if user wishes to make use of it:

```yaml
  - Name: hpc
    ComputeResources:
    - Name: hpc7a96xlarge
      Instances:
      - InstanceType: hpc7a.96xlarge
      MinCount: 1
      MaxCount: 10
      Efa:
        Enabled: true
``` 

Note that an EFA device counts towards the maximum number of network interfaces an instance can support. There are two types of EFA configuartions availble:
- **EFA with ENA**: This interface provides both an ENA device for standard, IP traffic and and EFA device for high-throughut, low-latency communication such as MPI.
- **EFA only**: This interface provides just the EFA device for high-througput, low-latency communication.

The WEKA installation script automatically provisions network interfaces and attaches them to nodes where DPDK will be used, and attempts to avoid conflicts with existing EFA devices. It also also handles detaching and deleting interfaces when instances are terminated (e.g. when dynamic nodes scale down).

When deciding on how many network interfaces to use, consider the following:

- WEKA will allocate one CPU core per network interface, and users can select how many cores to use
- You are limited to the maximum number of network interfaces for a particular instance type
- One network interface is required for the host OS (for standard IP traffic)

For intances that support EFA, the first EFA device attached to an instance must be an EFA with ENA; users are free to use either EFA with ENA or EFA-only interfaces for subsuquent attachments. By default, AWS ParallelCluster configures EFA with ENA, and provisions the maximum number of EFA devices supported for a particular instance type. This is important to note, as the EFA with ENA device allows for standard IP traffic, meaning we don't have to reduce the number of network interfaces allocated to WEKA.

For example, an `hpc7a.96xlarge` has **2 network cards** and supports a total of **4 network interfaces**. If a user enables EFA in their ParallelCluster (as in the above code sample), then 2 EFA with ENA interfaces will be provisioned, with an EFA device on each network card. That leaves 2 available spaces for additional network interfaces. Becuase the host OS can utilize the ENA device that was also configured for IP traffic, then 2 additional network interfaces can be created and allocated to WEKA processes. 

### Resource Allocation
As mentioned above, DPDK mode requires dedicated cores. Users are free to allocate as many cores as they wish, so long as the instance type can support the corresponding nubmer of ENIs. AWS instances can also different hardware layouts, and so it's important to choose cores that don't result in resource contention (e.g. core IDs that share a PCIe lane). We also recommend disabling hyperthreading for instances that will use DPDK mode. In ParallelCluster, this option can be configured with the `DisableSimultaneousMultithreading` parameter. Note that some instances like the HPC series come with hyperthreading automatically turned off.

In addition, these dedicated cores must be excluded from Slurm scheduling to provide an accurate resource allocation. ParallelCluster configuration allows for this, and the example template file shows how this can be done:

```yaml
Scheduling:
  Scheduler: slurm
  SlurmSettings:
    CustomSlurmSettings:
      - ProctrackType: proctrack/cgroup
      - TaskPluginParam: SlurmdOffSpec
      - SelectType: select/cons_tres
      - SelectTypeParameters: CR_Core_Memory
      - JobAcctGatherType: jobacct_gather/cgroup
      - PrologFlags: Contain
  
  ...

  - Name: hpc
    ComputeResources:
    - Name: hpc7a96xlarge
      Instances:
      - InstanceType: hpc7a.96xlarge
      MinCount: 1
      MaxCount: 10
      Efa:
        Enabled: true
      CustomSlurmSettings:
        RealMemory: 742110
        CpuSpecList: 95,191
```
In this example, we're isolating cores 95 and 191 for use with ENIs. We're also allocating 5GB of memory for the WEKA containers and reducing the total amount of `RealMemory`.

## Configuration Options

### Basic UDP Mode
```yaml
CustomActions:
  OnNodeConfigured:
    Sequence:
      - Script: s3://YOUR-BUCKET/scripts/virtualenv-setup.sh
      - Script: s3://YOUR-BUCKET/scripts/weka-install.sh
        Args:
          - "--backend-ip=your-weka-backend"
          - "--filesystem-name=default"
          - "--mount-point=/mnt/weka"
```

### DPDK Mode
```yaml
CustomActions:
  OnNodeConfigured:
    Sequence:
      - Script: s3://YOUR-BUCKET/scripts/virtualenv-setup.sh
      - Script: s3://YOUR-BUCKET/scripts/weka-install.sh
        Args:
          - "--filesystem-name=default"
          - "--mount-point=/mnt/weka"
          - "--cores=95,191"
          - "--security-groups=sg-xxxxx"
```

## Important Notes

- DPDK mode requires specific CPU core selection and memory consideration
- The WEKA insatll script automatically handles ENI creation and cleanup
- Systemd services are created for proper mount management
- Instance types must support the required number of network interfaces for DPDK mode

## Troubleshooting

Common issues and solutions:

1. Mount Failures
   - Check WEKA backend accessibility
   - Verify security group rules
   - Review systemd service logs: `journalctl -u weka-mount`

2. DPDK Mode Issues
   - Ensure instance type supports required network interfaces
   - Verify core isolation configuration
   - Check ENI creation permissions

3. General Debug Logs
   - ParallelCluster logs in CloudWatch
   - Installation logs in `/var/log/messages`
   - WEKA agent logs in `/var/log/weka/`


## Disclaimer

This implementation is provided as-is as a proof of concept. Users should thoroughly test and modify the scripts according to their specific requirements before any production use.
