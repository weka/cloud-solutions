#!/bin/bash

set -ex

BACKEND_IP="$1"

if [[ -z "$BACKEND_IP" ]]; then
  echo "Usage: $0 <backend_ip>"
  exit 1
fi

# validate that SUBNET_ID, FSX_ID, FSX_MOUNTNAME, SECURITY_GROUP, ROLE and BUCKET are set
if [[ -z "$SUBNET_ID" || -z "$FSX_ID" || -z "$FSX_MOUNTNAME" || -z "$SECURITY_GROUP" || -z "$ROLE" || -z "$BUCKET" ]]; then
  echo "Please set SUBNET_ID, FSX_ID, FSX_MOUNTNAME, SECURITY_GROUP, ROLE and BUCKET environment variables"
  exit 1
fi

CLUSTER_NAME="${CLUSTER_NAME:-sagemaker-hyperpod}"
INSTANCE_TYPE="${INSTANCE_TYPE:-p5.48xlarge}"
AWS_REGION="${AWS_REGION:-us-west-1}"
INSTANCE_COUNT="${INSTANCE_COUNT:-1}"
CONTROLLER_INSTANCE_TYPE="${CONTROLLER_INSTANCE_TYPE:-m5.12xlarge}"
LOGIN_GROUP_INSTANCE_TYPE="${LOGIN_GROUP_INSTANCE_TYPE:-m5.4xlarge}"
LOGIN_GROUP_INSTANCE_COUNT="${LOGIN_GROUP_INSTANCE_COUNT:-1}"
WORKER_EBS_VOLUME_SIZE="${WORKER_EBS_VOLUME_SIZE:-500}"
CONTROLLER_EBS_VOLUME_SIZE="${CONTROLLER_EBS_VOLUME_SIZE:-500}"
LOGIN_GROUP_EBS_VOLUME_SIZE="${LOGIN_GROUP_EBS_VOLUME_SIZE:-500}"
LOGIN_GROUP_NAME="${LOGIN_GROUP_NAME:-login-group}"
CONTROLLER_GROUP_NAME="${CONTROLLER_GROUP_NAME:-controller-machine}"
WORKER_GROUP_NAME="${WORKER_GROUP_NAME:-worker-group-1}"

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
  "controller_group": "${CONTROLLER_GROUP_NAME}",
  "login_group": "${LOGIN_GROUP_NAME}",
  "worker_groups": [
    {
      "instance_group_name": "${WORKER_GROUP_NAME}",
      "partition_name": "${INSTANCE_TYPE}"
    }
  ],
  "fsx_dns_name": "${FSX_ID}.fsx.${AWS_REGION}.amazonaws.com",
  "fsx_mountname": "${FSX_MOUNTNAME}"
}
EOL

cp lifecycle_script.py base-config
mkdir -p base-config/weka
cp set_weka.sh weka_slurm.py utils.py update_slurm_conf.sh base-config/weka
aws --region "$AWS_REGION" s3 cp --recursive base-config/ s3://${BUCKET}/src

cluster_config_file="cluster-config-$(date '+%Y-%m-%d_%H:%M:%S').json"
cat > "$cluster_config_file" << EOL
{
    "ClusterName": "${CLUSTER_NAME}",
    "InstanceGroups": [
      {
        "InstanceGroupName": "${CONTROLLER_GROUP_NAME}",
        "InstanceType": "ml.${CONTROLLER_INSTANCE_TYPE}",
        "InstanceStorageConfigs": [
          {
            "EbsVolumeConfig": {
              "VolumeSizeInGB": ${CONTROLLER_EBS_VOLUME_SIZE}
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
        "InstanceGroupName": "${LOGIN_GROUP_NAME}",
        "InstanceType": "ml.${LOGIN_GROUP_INSTANCE_TYPE}",
        "InstanceStorageConfigs": [
          {
            "EbsVolumeConfig": {
              "VolumeSizeInGB": ${LOGIN_GROUP_EBS_VOLUME_SIZE}
            }
          }
        ],
        "InstanceCount": ${LOGIN_GROUP_INSTANCE_COUNT},
        "LifeCycleConfig": {
          "SourceS3Uri": "s3://${BUCKET}/src",
          "OnCreate": "on_create.sh"
        },
        "ExecutionRole": "${ROLE}",
        "ThreadsPerCore": 1
      },
      {
        "InstanceGroupName": "${WORKER_GROUP_NAME}",
        "InstanceType": "ml.${INSTANCE_TYPE}",
        "InstanceStorageConfigs": [
          {
            "EbsVolumeConfig": {
              "VolumeSizeInGB": ${WORKER_EBS_VOLUME_SIZE}
            }
          }
        ],
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

rm base-config/provisioning_parameters.json base-config/lifecycle_script.py
rm -rf base-config/weka
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' "s/backend_ip=.*/backend_ip='<place holder>'/" set_weka.sh
else
    sed -i "s/backend_ip=.*/backend_ip='<place holder>'/" set_weka.sh
fi

if [[ -n "$TRAINING_PLAN_ARN" ]]; then
cat > add_train_plan.py << EOL
import json
conf = json.load(open('$cluster_config_file'))
for instance_group in conf['InstanceGroups']:
    if instance_group['InstanceGroupName'] == "${WORKER_GROUP_NAME}":
      instance_group['TrainingPlanArn'] = "$TRAINING_PLAN_ARN"
      break
json.dump(conf, open('$cluster_config_file', 'w'), indent=2)
print(json.dumps(conf, indent=2))
EOL
python3 add_train_plan.py
rm add_train_plan.py
fi

echo "cluster config file location: $(pwd)/$cluster_config_file"

aws --region "$AWS_REGION" sagemaker create-cluster --cli-input-json "file://$cluster_config_file" --output text --no-cli-pager
