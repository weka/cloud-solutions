#### ML AKS Clients
This repository provides tools for setting up and managing AKS clients for a Weka cluster.

The scripts and Terraform configurations streamline the creation of AKS clusters, ML workspaces, and the installation of Weka clients on AKS nodes

## How to run
- run cd azure/ml-aks
- Optional:
    - Create AKS cluster with dedicated client node pool
        - run cd aks
        - provide the required variables:
            - `rg_name`
            - `vnet_name`
            - `subnet_name`
            - `ssh_public_key`
            - `subscription_id`
            - `prefix`
            - `client_frontend_cores`
        - run `terraform init`
        - run `terraform apply`
    - Create ML workspace
        - run cd ml
        - provide the required variables:
            - `subscription_id`
            - `rg_name`
            - `key_vault_name`
            - `prefix`
        - run `terraform init`
        - run `terraform apply`
- Setup UDP WEKA clients on AKS nodepool:
    - Run `./set_env_vars.sh && source env_vars`
    - Run `./run.sh <weka_backend_ip>`

This script will update the aks clients with the weka cluster configuration, and will install the weka client on the aks clients
On each AKS client node, a DaemonSet ensures the creation of a pod named `installer-init-xxx`. This pod runs a specialized UDP mount script that seamlessly connects the node to the Weka cluster.
