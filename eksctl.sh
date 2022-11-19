#!/bin/bash

# https://karpenter.sh/preview/getting-started/getting-started-with-eksctl/

set -o nounset
set -o errexit
set -o xtrace

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export AWS_ACCOUNT_ID

export AWS_DEFAULT_REGION="us-east-1"

CLUSTER_NAME="${USER}-karpenter-demo-$(date +%Y%m%d%H)"
export CLUSTER_NAME

KARPENTER_VERSION=v$(curl -s https://api.github.com/repos/aws/karpenter/releases/latest | grep tag_name | cut -d '"' -f 4 | sed 's#v##')
export KARPENTER_VERSION

export KARPENTER_VERSION=v0.19.0
echo $KARPENTER_VERSION

time eksctl create cluster -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
  version: "1.23"
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}
managedNodeGroups:
- instanceType: m5.large
  amiFamily: AmazonLinux2
  name: ${CLUSTER_NAME}-ng
  desiredCapacity: 1
  minSize: 1
  maxSize: 10
iam:
  withOIDC: true
availabilityZones: ['us-east-1a', 'us-east-1b', 'us-east-1c', 'us-east-1d']
EOF

CLUSTER_ENDPOINT="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.endpoint" --output text)"
export CLUSTER_ENDPOINT
echo "$CLUSTER_ENDPOINT"

TEMPOUT=$(mktemp)

curl -fsSL "https://karpenter.sh/${KARPENTER_VERSION}/getting-started/getting-started-with-eksctl/cloudformation.yaml"

echo "$CLUSTER_NAME"

curl -fsSL "https://karpenter.sh/${KARPENTER_VERSION}/getting-started/getting-started-with-eksctl/cloudformation.yaml" >"$TEMPOUT" &&
    time aws cloudformation deploy \
        --stack-name "Karpenter-${CLUSTER_NAME}" \
        --template-file "${TEMPOUT}" \
        --capabilities CAPABILITY_NAMED_IAM \
        --parameter-overrides "ClusterName=${CLUSTER_NAME}"

time eksctl create iamidentitymapping \
    --username "system:node:{{EC2PrivateDNSName}}" \
    --cluster "${CLUSTER_NAME}" \
    --arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}" \
    --group system:bootstrappers \
    --group system:nodes

time eksctl create iamserviceaccount \
    --cluster "${CLUSTER_NAME}" --name karpenter --namespace karpenter \
    --role-name "${CLUSTER_NAME}-karpenter" \
    --attach-policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}" \
    --role-only \
    --approve

export KARPENTER_IAM_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter"
echo "$KARPENTER_IAM_ROLE_ARN"

time aws iam create-service-linked-role --aws-service-name spot.amazonaws.com || true

# https://karpenter.sh/preview/getting-started/getting-started-with-eksctl/#install-karpenter-helm-chart

time helm repo add karpenter https://charts.karpenter.sh/
time helm repo update

# export KARPENTER_VERSION=v0.10.1
# export AWS_DEFAULT_REGION="us-east-1"
# export CLUSTER_NAME="${USER}-karpenter-demo"
# export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
# export CLUSTER_ENDPOINT="$(aws eks describe-cluster --name ${CLUSTER_NAME} --query "cluster.endpoint" --output text)"
# export KARPENTER_IAM_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter"

echo KARPENTER_VERSION="$KARPENTER_VERSION"
echo AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION"
echo CLUSTER_NAME="$CLUSTER_NAME"
echo AWS_ACCOUNT_ID="$AWS_ACCOUNT_ID"
echo CLUSTER_ENDPOINT="$CLUSTER_ENDPOINT"
echo KARPENTER_IAM_ROLE_ARN="$KARPENTER_IAM_ROLE_ARN"

echo creating .vars.sh so we can cleanup
{
    echo export KARPENTER_VERSION="$KARPENTER_VERSION"
    echo export AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION"
    echo export CLUSTER_NAME="$CLUSTER_NAME"
    echo export AWS_ACCOUNT_ID="$AWS_ACCOUNT_ID"
    echo export CLUSTER_ENDPOINT="$CLUSTER_ENDPOINT"
    echo export KARPENTER_IAM_ROLE_ARN="$KARPENTER_IAM_ROLE_ARN"

} >.vars.sh
chmod +x .vars.sh

time helm upgrade --install --namespace karpenter --create-namespace \
    karpenter karpenter/karpenter \
    --version ${KARPENTER_VERSION} \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${KARPENTER_IAM_ROLE_ARN}" \
    --set clusterName="${CLUSTER_NAME}" \
    --set clusterEndpoint="${CLUSTER_ENDPOINT}" \
    --set aws.defaultInstanceProfile="KarpenterNodeInstanceProfile-${CLUSTER_NAME}" \
    --wait # for the defaulting webhook to install before creating a Provisioner

eksctl utils describe-stacks --region="${AWS_DEFAULT_REGION}" --cluster="${CLUSTER_NAME}"
eksctl utils update-cluster-logging --enable-types=all --region="${AWS_DEFAULT_REGION}" --cluster="${CLUSTER_NAME}" --approve

echo "${CLUSTER_NAME}"

# Provisioner
# https://karpenter.sh/preview/getting-started/getting-started-with-eksctl/#provisioner

cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1alpha5
kind: Provisioner
metadata:
  name: default
spec:
  requirements:
    - key: karpenter.sh/capacity-type
      operator: In
      values: ["spot"]
  limits:
    resources:
      cpu: 1000
  provider:
    subnetSelector:
      karpenter.sh/discovery: ${CLUSTER_NAME}
    securityGroupSelector:
      karpenter.sh/discovery: ${CLUSTER_NAME}
  ttlSecondsAfterEmpty: 30
EOF
