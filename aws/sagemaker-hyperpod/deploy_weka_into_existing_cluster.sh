#!/bin/bash

set -ex

BACKEND_IP="$1"
FILESYSTEM_NAME="$2"

if [[ -z "$BACKEND_IP" ]]; then
  echo "Usage: $0 <backend_ip> <filesystem_name>"
  exit 1
fi

if [[ -z "$FILESYSTEM_NAME" ]]; then
  echo "Usage: $0 <backend_ip> <filesystem_name>"
  exit 1
fi

# validate that BUCKET is set
if [[ -z "$BUCKET" ]]; then
  echo "Please set BUCKET environment variables"
  exit 1
fi

CLUSTER_NAME="${CLUSTER_NAME:-sagemaker-hyperpod}"
AWS_REGION="${AWS_REGION:-us-west-1}"

cd LifecycleScripts

mkdir -p existing-cluster-base-config
cp existing_cluster_lifecycle_script.py base-config/config.py existing-cluster-base-config
mkdir -p existing-cluster-base-config/weka
cp set_weka.sh weka_slurm.py utils.py update_slurm_conf.sh existing-cluster-base-config/weka
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' "s/backend_ip=.*/backend_ip=$BACKEND_IP/" existing-cluster-base-config/weka/set_weka.sh
  sed -i '' "s/FILESYSTEM_NAME=.*/FILESYSTEM_NAME=$FILESYSTEM_NAME/" existing-cluster-base-config/weka/set_weka.sh
else
  sed -i "s/backend_ip=.*/backend_ip=$BACKEND_IP/" existing-cluster-base-config/weka/set_weka.sh
  sed -i "s/FILESYSTEM_NAME=.*/FILESYSTEM_NAME=$FILESYSTEM_NAME/" existing-cluster-base-config/weka/set_weka.sh
fi
aws --region "$AWS_REGION" s3 cp --recursive existing-cluster-base-config/ s3://${BUCKET}/src/existing-cluster-base-config

rm -rf existing-cluster-base-config

python ../set_weka_in_existing_cluster.py "$CLUSTER_NAME"

echo "Successfully deployed Weka into the $CLUSTER_NAME cluster"
