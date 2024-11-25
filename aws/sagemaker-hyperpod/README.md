## SageMaker HyperPod with WEKA
The SageMaker HyperPod files here are copied from AWS [SageMaker HyperPod samples](https://github.com/aws-samples/awsome-distributed-training/tree/main/1.architectures/5.sagemaker-hyperpod)
<br>The unique files are:
- `set_weka.sh`: will set weka on the SageMaker HyperPod cluster nodes setup
- `set_env_vars.sh`: will set the required env vars for examples.sh
- `examples.sh`: will create the SageMaker HyperPod cluster with weka installed

The idea here is to have a simple example to create a SageMaker HyperPod cluster with WEKA installed, while our expectation
is, that WEKA customers will integrate `set_weka.sh` into their own SageMaker HyperPod cluster setup.

### Pre-requisites
- Weka cluster is up and running

The following AWS resources (can use AWS official [CF](https://catalog.workshops.aws/sagemaker-hyperpod/en-US/00-setup/02-own-account)):
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
- run `./set_env_vars.sh <stack_name> && source env_vars` if the pre-requisites are created using the CF above
- run `./examples.sh <weka backend ip> <SageMaker cluster_name>`
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