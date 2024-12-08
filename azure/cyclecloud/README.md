## Integrate Azure CycleCloud with WEKA

### Pre-requisites
1. Download the Azure CycleCloud / WEKA CycleCloud Template
2. Configure the network parameters to enable DPDK on the Azure CycleCloud Nodes
3. Create and deploy the cluster initialization module on the Azure CycleCloud Nodes
4. Configure the WEKA blade on the CycleCloud / Weka template installed in step 1.


### CycleCloud - Weka template
- On your CycleCloud VM, git clone the repository `https://github.com/themorey/cyclecloud-weka`
```bash
git clone https://github.com/themorey/cyclecloud-weka.git
```
- Import the template entitled “slurm-weka”
```bash
cyclecloud import_template -f /home/weka/cyclecloud-weka/templates/slurm-weka.txt
```
- Once successful, you will see the template in your CycleCloud GUI

### Azure CycleCloud VM
- Navigate to the CycleCloud / Weka Template that was downloaded in step before
- Scroll to the section called `[[nodearraybase]]` and add the following arguments
```bash
[[[network-interface eth0]]]
AssociatePublicIpAddress = $ExecuteNodesPublic
SubnetId = $SubnetId
AcceleratedNetworking = true

[[[network-interface eth1]]]
SubnetId = $SubnetId
```
- copy `weka_client_install.sh` script to vm. Depending on your configuration, you may create sperate Azure CycleCloud specs for each Node Array and have a cloud-init script for each array.
`~/specs/htc/cluster-init/scripts`

### CycleCloud GUI
- On your CycleCloud GUI, click Edit
- Click on `Advanced Settings` and scroll to the Cluster Init section near the bottom.
- Click on `Browse` and navigate to the cluster init for the desired node array. The example below shows the same cluster init script being deployed for the HTC and HPC nodes
- Click `Weka Cluster Info` fill in the parameters. The Weka Addresses are from step 1 above. You can specify any mount point you like, and the WEKA filesystem is one you have chosen in step 1 above. Note ensure you have separated each WEKA backend IP with a comma
- save

### Scheduler VM
- Log into the scheduler VM
- Run a SLURM job. For this example we have chosen to run a batch HTC job with 3 nodes
```bash
sbatch -p htc -N3 --wrap /bin/hostname
```
HTC Nodes have been activated via CycleCloud
For debuging:
- log into a HTC node and find the cluster-init script file
- Do a tail -f <script name> to see the VM going through the steps to mount to weka
