#!/bin/bash

backend_ip=$1

if [[ -z "$backend_ip" ]]; then
  echo "Usage: $0 <backend_ip>"
  exit 1
fi

subscription_id=${SUBSCRIPTION_ID}
if [ -z "$subscription_id" ]; then
    echo "SUBSCRIPTION_ID is not set"
    exit 1
fi

rg_name=${RG_NAME}
if [ -z "$rg_name" ]; then
    echo "RG_NAME is not set"
    exit 1
fi

aks_cluster_name=${AKS_CLUSTER_NAME}
if [ -z "$aks_cluster_name" ]; then
    echo "AKS_CLUSTER_NAME is not set"
    exit 1
fi

aks_clients_vmss_name=${AKS_CLIENTS_VMSS_NAME}
if [ -z "$aks_clients_vmss_name" ]; then
    echo "AKS_CLIENTS_VMSS_NAME is not set"
    exit 1
fi

backend_vmss_name=${BACKEND_VMSS_NAME}
if [ -z "$backend_vmss_name" ]; then
    echo "BACKEND_VMSS_NAME is not set"
    exit 1
fi

frontend_container_cores_num=${FRONTEND_CONTAINER_CORES_NUM}
if [ -z "$frontend_container_cores_num" ]; then
    echo "FRONTEND_CONTAINER_CORES_NUM is not set"
    exit 1
fi

filesystem_name=${FILESYSTEM_NAME}
if [ -z "$filesystem_name" ]; then
    echo "FILESYSTEM_NAME is not set"
    exit 1
fi

mount_point=${MOUNT_POINT}
if [ -z "$mount_point" ]; then
    echo "MOUNT_POINT is not set"
    exit 1
fi

# install yq if not installed
if ! command -v yq &> /dev/null
then
    echo "yq could not be found"
    apt install yq -y || brew install yq || yum install yq -y || true
fi

# install jq if not installed
if ! command -v jq &> /dev/null
then
    echo "jq could not be found"
    apt install jq -y || brew install jq || yum install jq -y || true
fi

# Set aks credentials
aks_kube_config_path=/tmp/$aks_cluster_name.yaml
az account set --subscription $subscription_id
az aks get-credentials --resource-group $rg_name --name $aks_cluster_name --file $aks_kube_config_path
export KUBECONFIG=$aks_kube_config_path

# install helm for mounting weka clients
helm upgrade --install mount-weka-clients ./chart \
  --set weka.backend_ip=$backend_ip \
  --set nodeSelector.agentpool=$aks_clients_vmss_name \
  --set weka.frontend_container_cores_num=$frontend_container_cores_num \
  --set weka.filesystem_name=$filesystem_name \
  --set weka.mount_point=$mount_point \

echo "============================================================"
echo "AKS kubeconfig file path is $aks_kube_config_path"
echo "export KUBECONFIG=$aks_kube_config_path to use it."