#!/bin/bash
clear
# A script to sync AWS infrastructure with Terraform state (only for resources already configured in Terraform)

#set -e  # Exit on error
set -o pipefail  # Exit if any part of a pipeline fails

# VARIABLES
AWS_REGION="us-east-1" # Change to your AWS region as needed
CLUSTER_NAME="<your_cluster_name>"  # Change to your cluster name

# Check prerequisites
command -v terraform >/dev/null 2>&1 || { echo >&2 "Terraform is required but not installed. Aborting."; exit 1; }
command -v aws >/dev/null 2>&1 || { echo >&2 "AWS CLI is required but not installed. Aborting."; exit 1; }

# Ensure Terraform is initialized
if [ ! -d ".terraform" ]; then
  echo "Initializing Terraform..."
  terraform init -input=false
fi

echo "Syncing AWS infrastructure with Terraform state for cluster: $CLUSTER_NAME in region: $AWS_REGION"

# Get the current state and list of Terraform-configured resources
echo "Fetching current Terraform state..."
terraform state list > terraform_state_list.txt || echo "No Terraform state found or state file not initialized."

# Fetch the configured resources from .tf file
echo "Determining Terraform-configured resources..."
terraform show -json | jq -r '.planned_values.root_module.resources[].address' > terraform_configured_resources.txt

# Sync SECURITY GROUPS
echo "Syncing Security Groups..."
SG_CLUSTER=$(aws ec2 describe-security-groups --filters Name=tag:Name,Values=${CLUSTER_NAME}-cluster --region $AWS_REGION --query "SecurityGroups[0].GroupId" --output text)
SG_NODE=$(aws ec2 describe-security-groups --filters Name=tag:Name,Values=${CLUSTER_NAME}-node --region $AWS_REGION --query "SecurityGroups[0].GroupId" --output text)

if grep -q "module.eks.aws_security_group.cluster" terraform_configured_resources.txt && [[ "$SG_CLUSTER" != "None" && ! $(grep "$SG_CLUSTER" terraform_state_list.txt) ]]; then
  echo "Importing Security Group for EKS Cluster: $SG_CLUSTER"
  terraform import module.eks.aws_security_group.cluster "$SG_CLUSTER"
fi

if grep -q "module.eks.aws_security_group.node" terraform_configured_resources.txt && [[ "$SG_NODE" != "None" && ! $(grep "$SG_NODE" terraform_state_list.txt) ]]; then
  echo "Importing Security Group for Node Group: $SG_NODE"
  terraform import module.eks.aws_security_group.node "$SG_NODE"
fi

# Sync NODE GROUPS
echo "Syncing Node Groups..."
NODE_GROUPS=$(aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $AWS_REGION --query "nodegroups[]" --output text)

if [[ -n "$NODE_GROUPS" ]]; then
  for NODE_GROUP in $NODE_GROUPS; do
    if grep -q "module.eks.aws_eks_node_group.${NODE_GROUP}" terraform_configured_resources.txt && ! grep -q "${NODE_GROUP}" terraform_state_list.txt; then
      echo "Importing Node Group: $NODE_GROUP"
      terraform import "module.eks.aws_eks_node_group.${NODE_GROUP}" "$CLUSTER_NAME:$NODE_GROUP"
    else
      echo "Node Group $NODE_GROUP is already synced in Terraform state or not part of Terraform configuration."
    fi
  done
else
  echo "No Node Groups found for the EKS Cluster: $CLUSTER_NAME."
fi

# Sync EKS CLUSTER
echo "Syncing the EKS Cluster..."
EKS_CLUSTER=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.name' --output text)

if grep -q "module.eks.aws_eks_cluster.this" terraform_configured_resources.txt && [[ "$EKS_CLUSTER" != "None" && ! $(grep -q "module.eks.aws_eks_cluster.this" terraform_state_list.txt) ]]; then
  echo "Importing EKS Cluster: $EKS_CLUSTER"
  terraform import module.eks.aws_eks_cluster.this "$EKS_CLUSTER"
else
  echo "EKS Cluster $EKS_CLUSTER is already synced in Terraform state or not part of Terraform configuration."
fi

# Cleanup
rm -f terraform_state_list.txt terraform_configured_resources.txt

echo "Sync complete!"
