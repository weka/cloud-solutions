#### ML AKS Clients
Create ml aks clients for weka cluster

## How to run

provide the following variables in terraform.tfvars file:

```bash
backend_vmss_name     = VMSS_NAME
create_ml             = true
subnet_name           = SUBNET_NAME
vnet_name             = VNET_NAME
subscription_id       = SUBSCRIPTION_ID
rg_name               = RG_NAME
ssh_public_key        = Standard_L8s_v3
key_vault_name        = KEY_VAULT_NAME
cluster_name          = CLUSTER_NAME
prefix                = PREFIX
node_count            = 3
instance_type         = "Standard_L8s_v3"
client_frontend_cores = 1
vm_username           = "weka"
os_sku                = "Ubuntu"
```
Run the following commands:
```bash
terraform init
terraform apply
```
In the output you will get the `/tmp/update_aks_node_pool_<prefix>_<cluster-name>.sh` script to run on the aks clients
```bash
/tmp/update_aks_node_pool_<prefix>_<cluster-name>.sh
```
This script will update the aks clients with the weka cluster configuration, and will install the weka client on the aks clients
On each AKS client node, a DaemonSet ensures the creation of a pod named `installer-init-xxx`. This pod runs a specialized UDP mount script that seamlessly connects the node to the Weka cluster.
