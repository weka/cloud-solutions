#!/bin/bash

STACK_NAME=$1

if [[ -z "$STACK_NAME" ]]; then
  echo "Usage: $0 <STACK_NAME>"
  exit 1
fi

stack_outputs=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME"  --query 'Stacks[0].Outputs' --output json)

export SUBNET_ID=$(echo "$stack_outputs" | jq '.[]|select(.OutputKey=="PrimaryPrivateSubnet").OutputValue')

if [[ -n $SUBNET_ID ]]; then
    echo "export SUBNET_ID=${SUBNET_ID}" > env_vars
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


