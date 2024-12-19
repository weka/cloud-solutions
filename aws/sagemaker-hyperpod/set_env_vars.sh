#!/bin/bash

STACK_NAME=$1

if [[ -z "$STACK_NAME" ]]; then
  echo "Usage: $0 <STACK_NAME>"
  exit 1
fi

get_input() {
    local prompt="$1"
    local default="$2"
    local input
    read -e -p "$prompt [$default]: " input
    echo "${input:-$default}"
}

export CONTROLLER_INSTANCE_TYPE=$(get_input "Enter the instance type for the controller group" "m5.12xlarge")
echo "export CONTROLLER_INSTANCE_TYPE=${CONTROLLER_INSTANCE_TYPE}" > env_vars
export CONTROLLER_EBS_VOLUME_SIZE=$(get_input "Enter the EBS volume size for the controller group" "500")
echo "export CONTROLLER_EBS_VOLUME_SIZE=${CONTROLLER_EBS_VOLUME_SIZE}" >> env_vars
export CONTROL_GROUP_NAME=$(get_input "Enter the name for the controller group" "controller-machine")
echo "export CONTROL_GROUP_NAME=${CONTROL_GROUP_NAME}" >> env_vars
export LOGIN_GROUP_INSTANCE_TYPE=$(get_input "Enter the instance type for the login group" "m5.4xlarge")
echo "export LOGIN_GROUP_INSTANCE_TYPE=${LOGIN_GROUP_INSTANCE_TYPE}" >> env_vars
export LOGIN_GROUP_INSTANCE_COUNT=$(get_input "Enter the number of instances for the login group" "1")
echo "export LOGIN_GROUP_INSTANCE_COUNT=${LOGIN_GROUP_INSTANCE_COUNT}" >> env_vars
export LOGIN_GROUP_EBS_VOLUME_SIZE=$(get_input "Enter the EBS volume size for the login group" "500")
echo "export LOGIN_GROUP_EBS_VOLUME_SIZE=${LOGIN_GROUP_EBS_VOLUME_SIZE}" >> env_vars
export LOGIN_GROUP_NAME=$(get_input "Enter the name for the login group" "login-group")
echo "export LOGIN_GROUP_NAME=${LOGIN_GROUP_NAME}" >> env_vars
export INSTANCE_TYPE=$(get_input "Enter the instance type for the worker group" "p5.48xlarge")
echo "export INSTANCE_TYPE=${INSTANCE_TYPE}" >> env_vars
export INSTANCE_COUNT=$(get_input "Enter the number of instances for the worker group" "1")
echo "export INSTANCE_COUNT=${INSTANCE_COUNT}" >> env_vars
export WORKER_EBS_VOLUME_SIZE=$(get_input "Enter the EBS volume size for the worker group" "500")
echo "export WORKER_EBS_VOLUME_SIZE=${WORKER_EBS_VOLUME_SIZE}" >> env_vars
export WORKER_GROUP_NAME=$(get_input "Enter the name for the worker group" "worker-group-1")
echo "export WORKER_GROUP_NAME=${WORKER_GROUP_NAME}" >> env_vars
export TRAINING_PLAN_ARN=$(get_input "Enter the training plan ARN" "")
echo "export TRAINING_PLAN_ARN=${TRAINING_PLAN_ARN}" >> env_vars
export CLUSTER_NAME=$(get_input "Enter the cluster name" "sagemaker-hyperpod")
echo "export CLUSTER_NAME=${CLUSTER_NAME}" >> env_vars

stack_outputs=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME"  --query 'Stacks[0].Outputs' --output json)

export SUBNET_ID=$(echo "$stack_outputs" | jq '.[]|select(.OutputKey=="PrimaryPrivateSubnet").OutputValue')

if [[ -n $SUBNET_ID ]]; then
    echo "export SUBNET_ID=${SUBNET_ID}" >> env_vars
    echo "[INFO] SUBNET_ID = ${SUBNET_ID}"
else
    echo "[ERROR] failed to retrieve SUBNET ID"
    exit 1
fi

export FSX_ID=$(echo "$stack_outputs" | jq '.[]|select(.OutputKey=="FSxLustreFilesystemId").OutputValue')

if [[ -n $FSX_ID ]]; then
    echo "export FSX_ID=${FSX_ID}" >> env_vars
    echo "[INFO] FSX_ID = ${FSX_ID}"
else
    echo "[ERROR] failed to retrieve FSX ID"
    exit 1
fi

export FSX_MOUNTNAME=$(echo "$stack_outputs" | jq '.[]|select(.OutputKey=="FSxLustreFilesystemMountname").OutputValue')

if [[ -n $FSX_MOUNTNAME ]]; then
    echo "export FSX_MOUNTNAME=${FSX_MOUNTNAME}" >> env_vars
    echo "[INFO] FSX_MOUNTNAME = ${FSX_MOUNTNAME}"
else
    echo "[ERROR] failed to retrieve FSX Mountname"
    exit 1
fi

export SECURITY_GROUP=$(echo "$stack_outputs" | jq '.[]|select(.OutputKey=="SecurityGroup").OutputValue')

if [[ -n $SECURITY_GROUP ]]; then
    echo "export SECURITY_GROUP=${SECURITY_GROUP}" >> env_vars
    echo "[INFO] SECURITY_GROUP = ${SECURITY_GROUP}"
else
    echo "[ERROR] failed to retrieve FSX Security Group"
    exit 1
fi

export ROLE=$(echo "$stack_outputs" | jq '.[]|select(.OutputKey=="AmazonSagemakerClusterExecutionRoleArn").OutputValue')

if [[ -n $ROLE ]]; then
    echo "export ROLE=${ROLE}" >> env_vars
    echo "[INFO] ROLE = ${ROLE}"
else
    echo "[ERROR] failed to retrieve Role ARN"
    exit 1
fi

export BUCKET=$(echo "$stack_outputs" | jq '.[]|select(.OutputKey=="AmazonS3BucketName").OutputValue')

if [[ -n $BUCKET ]]; then
    echo "export BUCKET=${BUCKET}" >> env_vars
    echo "[INFO] BUCKET = ${BUCKET}"
else
    echo "[ERROR] failed to retrieve Bucket Name"
    exit 1
fi

export AWS_REGION=$(aws configure list | grep region | awk '{print $2}')
if [[ -n $AWS_REGION ]]; then
    echo "export AWS_REGION=${AWS_REGION}" >> env_vars
    echo "[INFO] AWS_REGION = ${AWS_REGION}"
else
    echo "[ERROR] failed to retrieve region Name"
    exit 1
fi

echo "[INFO] CONTROLLER_INSTANCE_TYPE = ${CONTROLLER_INSTANCE_TYPE}"
echo "[INFO] CONTROLLER_EBS_VOLUME_SIZE = ${CONTROLLER_EBS_VOLUME_SIZE}"
echo "[INFO] CONTROL_GROUP_NAME = ${CONTROL_GROUP_NAME}"
echo "[INFO] LOGIN_GROUP_INSTANCE_TYPE = ${LOGIN_GROUP_INSTANCE_TYPE}"
echo "[INFO] LOGIN_GROUP_INSTANCE_COUNT = ${LOGIN_GROUP_INSTANCE_COUNT}"
echo "[INFO] LOGIN_GROUP_EBS_VOLUME_SIZE = ${LOGIN_GROUP_EBS_VOLUME_SIZE}"
echo "[INFO] LOGIN_GROUP_NAME = ${LOGIN_GROUP_NAME}"
echo "[INFO] INSTANCE_TYPE = ${INSTANCE_TYPE}"
echo "[INFO] INSTANCE_COUNT = ${INSTANCE_COUNT}"
echo "[INFO] WORKER_EBS_VOLUME_SIZE = ${WORKER_EBS_VOLUME_SIZE}"
echo "[INFO] WORKER_GROUP_NAME = ${WORKER_GROUP_NAME}"
echo "[INFO] TRAINING_PLAN_ARN = ${TRAINING_PLAN_ARN}"
echo "[INFO] CLUSTER_NAME = ${CLUSTER_NAME}"
