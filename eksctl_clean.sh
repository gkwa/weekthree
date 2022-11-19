#!/bin/bash

set -o nounset
set -o xtrace

echo AWS_ACCOUNT_ID="$AWS_ACCOUNT_ID"
echo AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION"
echo CLUSTER_ENDPOINT="$CLUSTER_ENDPOINT"
echo CLUSTER_NAME="$CLUSTER_NAME"
echo KARPENTER_IAM_ROLE_ARN="$KARPENTER_IAM_ROLE_ARN"
echo KARPENTER_VERSION="$KARPENTER_VERSION"

time helm uninstall karpenter --namespace karpenter
aws iam detach-role-policy --role-name="${CLUSTER_NAME}-karpenter" --policy-arn="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}"
aws iam delete-policy --policy-arn="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}"
aws iam delete-role --role-name="${CLUSTER_NAME}-karpenter"
time aws cloudformation delete-stack --stack-name "Karpenter-${CLUSTER_NAME}"
aws ec2 describe-launch-templates \
    | jq -r ".LaunchTemplates[].LaunchTemplateName" \
    | grep -i "Karpenter-${CLUSTER_NAME}" \
    | xargs -I{} aws ec2 delete-launch-template --launch-template-name {}
time eksctl delete cluster --name "${CLUSTER_NAME}"
