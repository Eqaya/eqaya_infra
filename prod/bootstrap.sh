#!/usr/bin/env bash
#
# One-time AWS bootstrap for the production deploy pipeline.
#
# Creates the resources Terraform's backend and the GitHub Actions OIDC flow
# need to exist BEFORE the first `terraform init`/apply can run:
#   1. S3 state bucket (idempotent; enables versioning + encryption)
#   2. DynamoDB state-lock table  (eqaya-tf-locks)
#   3. GitHub OIDC identity provider in IAM
#   4. IAM deploy role assumed by GitHub Actions (the AWS_ROLE_TO_ASSUME secret)
#
# Run ONCE, with admin-ish AWS credentials (NOT the deploy role this creates).
# Safe to re-run: every step checks for existing resources first.
#
# Usage:
#   ./bootstrap.sh
#
set -euo pipefail

# ---- config (override via env) ----
AWS_REGION="${AWS_REGION:-us-east-1}"
STATE_BUCKET="${STATE_BUCKET:-eqaya-infra-tf-state}"
LOCK_TABLE="${LOCK_TABLE:-eqaya-tf-locks}"
GH_ORG="${GH_ORG:-Eqaya}"
INFRA_REPO="${INFRA_REPO:-eqaya_infra}"
DEPLOY_ROLE_NAME="${DEPLOY_ROLE_NAME:-eqaya-prod-github-deploy}"
# The deploy job runs under `environment: production`, so its OIDC `sub` claim
# is exactly this. Scope the trust to it (tightest correct value).
OIDC_SUB="repo:${GH_ORG}/${INFRA_REPO}:environment:production"
OIDC_HOST="token.actions.githubusercontent.com"
# GitHub's OIDC thumbprint (AWS now validates via its CA, but the API wants one).
OIDC_THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "Account: ${ACCOUNT_ID}  Region: ${AWS_REGION}"

# ---- 1. S3 state bucket ----
if aws s3api head-bucket --bucket "${STATE_BUCKET}" 2>/dev/null; then
  echo "[ok] state bucket ${STATE_BUCKET} exists"
else
  echo "[create] state bucket ${STATE_BUCKET}"
  if [ "${AWS_REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${STATE_BUCKET}" --region "${AWS_REGION}"
  else
    aws s3api create-bucket --bucket "${STATE_BUCKET}" --region "${AWS_REGION}" \
      --create-bucket-configuration LocationConstraint="${AWS_REGION}"
  fi
fi
aws s3api put-bucket-versioning --bucket "${STATE_BUCKET}" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "${STATE_BUCKET}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "${STATE_BUCKET}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
echo "[ok] state bucket configured (versioning + encryption + public-access-block)"

# ---- 2. DynamoDB lock table ----
if aws dynamodb describe-table --table-name "${LOCK_TABLE}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "[ok] lock table ${LOCK_TABLE} exists"
else
  echo "[create] lock table ${LOCK_TABLE}"
  aws dynamodb create-table \
    --table-name "${LOCK_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${AWS_REGION}" >/dev/null
  aws dynamodb wait table-exists --table-name "${LOCK_TABLE}" --region "${AWS_REGION}"
  echo "[ok] lock table created"
fi

# ---- 3. GitHub OIDC provider ----
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_ARN}" >/dev/null 2>&1; then
  echo "[ok] OIDC provider exists"
else
  echo "[create] GitHub OIDC provider"
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_HOST}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "${OIDC_THUMBPRINT}" >/dev/null
  echo "[ok] OIDC provider created"
fi

# ---- 4. IAM deploy role ----
TRUST_POLICY="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_HOST}:aud": "sts.amazonaws.com",
        "${OIDC_HOST}:sub": "${OIDC_SUB}"
      }
    }
  }]
}
JSON
)"

if aws iam get-role --role-name "${DEPLOY_ROLE_NAME}" >/dev/null 2>&1; then
  echo "[update] deploy role ${DEPLOY_ROLE_NAME} trust policy"
  aws iam update-assume-role-policy --role-name "${DEPLOY_ROLE_NAME}" \
    --policy-document "${TRUST_POLICY}"
else
  echo "[create] deploy role ${DEPLOY_ROLE_NAME}"
  aws iam create-role --role-name "${DEPLOY_ROLE_NAME}" \
    --description "GitHub Actions OIDC role that applies prod/ Terraform" \
    --assume-role-policy-document "${TRUST_POLICY}" >/dev/null
fi

# This role creates IAM roles, VPC, RDS, ECS, ELB, ACM, Route53, S3, ECR,
# Secrets Manager, ElastiCache, WAF, CloudWatch, SNS, Budgets + state I/O.
# AdministratorAccess is the simplest correct grant; tighten to a scoped policy
# once the resource set is stable (follow-up, not a launch blocker).
aws iam attach-role-policy --role-name "${DEPLOY_ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess"

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${DEPLOY_ROLE_NAME}"
echo
echo "==================================================================="
echo "AWS bootstrap complete."
echo "Set this as the GitHub secret AWS_ROLE_TO_ASSUME:"
echo "  ${ROLE_ARN}"
echo "==================================================================="
