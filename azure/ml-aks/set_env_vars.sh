#!/bin/bash

get_input() {
    local prompt="$1"
    local default="$2"
    local input
    read -e -p "$prompt [$default]: " input
    echo "${input:-$default}"
}

export RG_NAME=$(get_input "Enter the resource group name" "ml-aks-rg")
echo "export RG_NAME=${RG_NAME}" > env_vars
export AKS_CLUSTER_NAME=$(get_input "Enter the AKS cluster name" "aks-cluster")
echo "export AKS_CLUSTER_NAME=${AKS_CLUSTER_NAME}" >> env_vars
export AKS_CLIENTS_VMSS_NAME=$(get_input "Enter the AKS clients vmss name" "clients")
echo "export AKS_CLIENTS_VMSS_NAME=${AKS_CLIENTS_VMSS_NAME}" >> env_vars
export FRONTEND_CONTAINER_CORES_NUM=$(get_input "Enter the frontend container core number" "1")
echo "export FRONTEND_CONTAINER_CORES_NUM=${FRONTEND_CONTAINER_CORES_NUM}" >> env_vars
export FILESYSTEM_NAME=$(get_input "Enter the filesystem name" "default")
echo "export FILESYSTEM_NAME=${FILESYSTEM_NAME}" >> env_vars
export MOUNT_POINT=$(get_input "Enter the mount path" "/mnt/weka")
echo "export MOUNT_POINT=${MOUNT_POINT}" >> env_vars
export SUBSCRIPTION_ID=$(get_input "Enter the subscription id" "00000000-0000-0000-0000-000000000000")
echo "export SUBSCRIPTION_ID=${SUBSCRIPTION_ID}" >> env_vars

echo "----------------------------------------"
echo "[INFO] env_vars file has been created with the above values"
echo "----------------------------------------"
echo "[INFO] SUBSCRIPTION_ID = ${SUBSCRIPTION_ID}"
echo "[INFO] RG_NAME = ${RG_NAME}"
echo "[INFO] AKS_CLUSTER_NAME = ${AKS_CLUSTER_NAME}"
echo "[INFO] AKS_CLIENTS_VMSS_NAME = ${AKS_CLIENTS_VMSS_NAME}"
echo "[INFO] FRONTEND_CONTAINER_CORES_NUM = ${FRONTEND_CONTAINER_CORES_NUM}"
echo "[INFO] FILESYSTEM_NAME = ${FILESYSTEM_NAME}"
echo "[INFO] MOUNT_POINT = ${MOUNT_POINT}"
