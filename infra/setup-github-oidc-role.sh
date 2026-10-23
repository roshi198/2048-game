#!/usr/bin/env bash
#
# Create the IAM role that GitHub Actions assumes via OIDC to deploy the game.
# Uses the AWS CLI directly (CloudFormation is blocked by SCP in this account).
#
# Run this ONCE, from a machine with admin AWS access, before enabling the
# GitHub Actions workflow. It is idempotent (safe to re-run).
#
# Usage:
#   GITHUB_ORG=roshi198 GITHUB_REPO=2048-game ./infra/setup-github-oidc-role.sh
#
set -euo pipefail

GITHUB_ORG="${GITHUB_ORG:?set GITHUB_ORG (e.g. roshi198)}"
GITHUB_REPO="${GITHUB_REPO:?set GITHUB_REPO (e.g. 2048-game)}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
ROLE_NAME="${ROLE_NAME:-${GITHUB_REPO}-gha-deploy}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
OIDC_HOST="token.actions.githubusercontent.com"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"

echo "==> Account: $ACCOUNT_ID | Role: $ROLE_NAME | repo: ${GITHUB_ORG}/${GITHUB_REPO}@${GITHUB_BRANCH}"

# -------- 1. Ensure the GitHub OIDC provider exists (one per account) --------
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  echo "==> OIDC provider already exists"
else
  echo "==> Creating GitHub OIDC provider"
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_HOST}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" >/dev/null
fi

# -------- 2. Trust policy: only this repo+branch may assume the role --------
TRUST="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "${OIDC_HOST}:aud": "sts.amazonaws.com" },
      "StringLike": { "${OIDC_HOST}:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/${GITHUB_BRANCH}" }
    }
  }]
}
JSON
)"

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "==> Role exists; updating trust policy"
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST"
else
  echo "==> Creating role"
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST" \
    --max-session-duration 3600 >/dev/null
fi

# -------- 3. Inline permissions policy (S3 + CloudFront only; NO CFN) --------
PERMS="$(cat <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket", "s3:PutBucketPolicy", "s3:GetBucketPolicy",
        "s3:PutEncryptionConfiguration", "s3:PutBucketPublicAccessBlock",
        "s3:GetBucketPublicAccessBlock", "s3:ListBucket",
        "s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:HeadBucket"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudFront",
      "Effect": "Allow",
      "Action": [
        "cloudfront:CreateDistribution", "cloudfront:GetDistribution",
        "cloudfront:GetDistributionConfig", "cloudfront:UpdateDistribution",
        "cloudfront:ListDistributions", "cloudfront:TagResource",
        "cloudfront:CreateOriginAccessControl", "cloudfront:GetOriginAccessControl",
        "cloudfront:ListOriginAccessControls", "cloudfront:UpdateOriginAccessControl",
        "cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"
      ],
      "Resource": "*"
    }
  ]
}
JSON
)"

echo "==> Attaching inline permissions policy"
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "deploy-2048" --policy-document "$PERMS"

ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"

echo ""
echo "============================================================"
echo " Role ready!"
echo "   Role ARN: $ROLE_ARN"
echo ""
echo " Add this as a GitHub repository VARIABLE named"
echo " AWS_DEPLOY_ROLE_ARN:"
echo "   Settings -> Secrets and variables -> Actions -> Variables"
echo "============================================================"
