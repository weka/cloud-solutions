import os
import sys

import boto3
import subprocess
if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("Usage: python existing_cluster_example.py <cluster-name>")
        sys.exit(1)

    clusterName = sys.argv[1]

    sagemaker_client = boto3.client('sagemaker')
    nodes = sagemaker_client.list_cluster_nodes(ClusterName=clusterName)
    clusterHash = sagemaker_client.describe_cluster(ClusterName=clusterName)['ClusterArn'].split('/')[-1]

    targetsMap = dict()
    targets = []
    target_template = 'sagemaker-cluster:{}_{}-{}'
    ids = []
    for node in nodes['ClusterNodeSummaries']:
        if node['InstanceGroupName'] not in targetsMap:
            targetsMap[node['InstanceGroupName']] = []

        target = target_template.format(clusterHash, node['InstanceGroupName'], node['InstanceId'])
        targetsMap[node['InstanceGroupName']].append(target)
        targets.append(target)
        ids.append(node['InstanceId'])

    ssm_client = boto3.client('ssm')

    for target in targets:
        # TODO: Move to boto3 ssm client, due to some bash syntax issue the remote command didn't run properly this way
        ssm_command = f"aws ssm start-session --target {target} --document-name 'AWS-StartNonInteractiveCommand'"
        bash_command_template = ' --parameters \'{{\"command\": ["bash -c \\"{}\\""]}}\''

        BUCKET = os.environ.get('BUCKET')
        AWS_REGION = os.environ.get('AWS_REGION')
        PROVISIONING_PARAMETERS_PATH = "/opt/ml/config/provisioning_parameters.json"
        SAGEMAKER_RESOURCE_CONFIG_PATH = "/opt/ml/config/resource_config.json"
        LOG_FILE = "/var/log/provision/weka.log"

        bash_command = ('mkdir -p /tmp/existing-cluster-base-config && '
                        f'aws --region {AWS_REGION} s3 cp --recursive '
                        f's3://{BUCKET}/src/existing-cluster-base-config /tmp/existing-cluster-base-config/ && '
                        'cd /tmp/existing-cluster-base-config && '
                        f'python3 existing_cluster_lifecycle_script.py -rc {SAGEMAKER_RESOURCE_CONFIG_PATH} '
                        f'-pp {PROVISIONING_PARAMETERS_PATH} >  >(tee -a {LOG_FILE}) 2>&1'
                        )

        subprocess.run(ssm_command + bash_command_template.format(bash_command), shell=True, check=True)
