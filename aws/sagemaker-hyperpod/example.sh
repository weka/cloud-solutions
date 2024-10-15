#!/bin/bash

set -ex

BACKEND_IP="$1"

if [[ -z "$BACKEND_IP" ]]; then
  echo "Usage: $0 <backend_ip>"
  exit 1
fi

CLUSTER_NAME="$2"
if [[ -z "$CLUSTER_NAME" ]]; then
  CLUSTER_NAME="sagemaker-hyperpod"
fi

# validate that SUBNET_ID, FSX_ID, FSX_MOUNTNAME, SECURITY_GROUP, ROLE and BUCKET are set
if [[ -z "$SUBNET_ID" || -z "$FSX_ID" || -z "$FSX_MOUNTNAME" || -z "$SECURITY_GROUP" || -z "$ROLE" || -z "$BUCKET" ]]; then
  echo "Please set SUBNET_ID, FSX_ID, FSX_MOUNTNAME, SECURITY_GROUP, ROLE and BUCKET environment variables"
  exit 1
fi

INSTANCE_TYPE="${INSTANCE_TYPE:-p5.48xlarge}"
AWS_REGION="${AWS_REGION:-us-west-1}"
INSTANCE_COUNT="${INSTANCE_COUNT:-1}"
CONTROLLER_INSTANCE_TYPE="${CONTROLLER_INSTANCE_TYPE:-m5.xlarge}"
EBS_VOLUME_SIZE="100"

cd LifecycleScripts
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' "s/backend_ip=.*/backend_ip=$BACKEND_IP/" set_weka.sh
else
    sed -i "s/backend_ip=.*/backend_ip=$BACKEND_IP/" set_weka.sh
fi

cat > base-config/provisioning_parameters.json << EOL
{
  "version": "1.0.0",
  "workload_manager": "slurm",
  "controller_group": "controller-machine",
  "worker_groups": [
    {
      "instance_group_name": "worker-group-1",
      "partition_name": "${INSTANCE_TYPE}"
    }
  ],
  "fsx_dns_name": "${FSX_ID}.fsx.${AWS_REGION}.amazonaws.com",
  "fsx_mountname": "${FSX_MOUNTNAME}"
}
EOL

cp set_weka.sh lifecycle_script.py base-config
aws --region "$AWS_REGION" s3 cp --recursive base-config/ s3://${BUCKET}/src

cat > cluster-config.json << EOL
{
    "ClusterName": "${CLUSTER_NAME}",
    "InstanceGroups": [
      {
        "InstanceGroupName": "controller-machine",
        "InstanceType": "ml.${CONTROLLER_INSTANCE_TYPE}",
        "InstanceStorageConfigs": [
          {
            "EbsVolumeConfig": {
              "VolumeSizeInGB": ${EBS_VOLUME_SIZE}
            }
          }
        ],
        "InstanceCount": 1,
        "LifeCycleConfig": {
          "SourceS3Uri": "s3://${BUCKET}/src",
          "OnCreate": "on_create.sh"
        },
        "ExecutionRole": "${ROLE}",
        "ThreadsPerCore": 1
      },
      {
        "InstanceGroupName": "worker-group-1",
        "InstanceType": "ml.${INSTANCE_TYPE}",
        "InstanceCount": ${INSTANCE_COUNT},
        "LifeCycleConfig": {
          "SourceS3Uri": "s3://${BUCKET}/src",
          "OnCreate": "on_create.sh"
        },
        "ExecutionRole": "${ROLE}",
        "ThreadsPerCore": 1
      }
    ],
    "VpcConfig": {
      "SecurityGroupIds": ["$SECURITY_GROUP"],
      "Subnets":["$SUBNET_ID"]
    }
}
EOL

aws --region "$AWS_REGION" sagemaker create-cluster --cli-input-json "file://cluster-config.json" --output text --no-cli-pager
rm cluster-config.json base-config/provisioning_parameters.json base-config/set_weka.sh base-config/lifecycle_script.py
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' "s/backend_ip=.*/backend_ip='<place holder>'/" set_weka.sh
else
    sed -i "s/backend_ip=.*/backend_ip='<place holder>'/" set_weka.sh
fi
