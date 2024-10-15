# Cloud Solutions

## SageMaker HyperPod
### Pre-requisites
Can use AWS official CF to generate the requires resources: https://catalog.workshops.aws/sagemaker-hyperpod/en-US/00-setup/02-own-account
- Fsx
- VPC
- Subnet
- SG
- IAM ROLE
- S3 Bucket

### Create SageMaker HyperPod Cluster
- set the required aws profile
- update the parameters in the examples.sh
- run `cd aws/sagemaker-hyperpod`
- run `./set_env_vars.sh <stack_name>`
- run `source env_vars`
- run `./examples.sh <backend ip> <SageMaker cluster_name>`
<br>The example will run by default with:
  - INSTANCE_TYPE=`p5.48xlarge`, for other instance type, set the INSTANCE_TYPE env var
  - AWS_REGION=`us-west-1`, for other region, set the AWS_REGION env var
  - INSTANCE_COUNT=`1`, for other instance count, set the INSTANCE_COUNT env var
  - CONTROLLER_INSTANCE_TYPE=`m5.xlarge`, for other controller instance type, set the CONTROLLER_INSTANCE_TYPE env var

### Access the nodes
```shell
./easy-ssh.sh <cluster_name>
sudo su -l ubuntu
ssh-keygen -t rsa -q -f "$HOME/.ssh/id_rsa" -N ""
cat .ssh/id_rsa.pub >> .ssh/authorized_keys
```
now you can run `sinfo` and ssh to one of the worker nodes
`ssh -i ~/.ssh/id_rsa ubuntu@<worker_ip>`
