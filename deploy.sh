#!/usr/bin/env bash
#
# Deploy the 2048 game to AWS (S3 + CloudFront) using ONLY the AWS CLI.
#
# This script does NOT use CloudFormation (it is blocked by an SCP in some
# accounts). It creates resources imperatively and is idempotent: re-running
# updates content and reuses existing infrastructure.
#
# Architecture:
#   - Private S3 bucket (no public access)
#   - CloudFront distribution with Origin Access Control (OAC)
#   - Bucket policy allowing only this distribution to read objects
#   - HTTPS, compression, SPA-friendly error handling
#
# Prerequisites:
#   - AWS CLI v2, configured with S3 + CloudFront permissions.
#   - `jq` for JSON manipulation.
#
# Usage:
#   ./deploy.sh
#   BUCKET=my-unique-2048-bucket REGION=us-east-1 ./deploy.sh
#
set -euo pipefail

# -------- Config (override via environment variables) --------
REGION="${REGION:-us-east-1}"
# Bucket name must be globally unique. Default derives one from the account id.
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${BUCKET:-game-2048-${ACCOUNT_ID}}"
OAC_NAME="game-2048-oac"
CALLER_REF="game-2048-${ACCOUNT_ID}"   # stable ref so we can find our distribution
SITE_DIR="$(cd "$(dirname "$0")" && pwd)"

command -v jq >/dev/null || { echo "ERROR: jq is required (brew install jq)"; exit 1; }

echo "==> Account: $ACCOUNT_ID | Region: $REGION | Bucket: $BUCKET"

# ============================================================
# 1. Create the S3 bucket (private) if it doesn't exist
# ============================================================
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "==> Bucket already exists: $BUCKET"
else
  echo "==> Creating bucket: $BUCKET"
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi

echo "==> Locking down public access + enabling encryption"
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# ============================================================
# 2. Origin Access Control (OAC) — reuse if present
# ============================================================
echo "==> Ensuring Origin Access Control: $OAC_NAME"
OAC_ID="$(aws cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id | [0]" \
  --output text 2>/dev/null || echo "None")"

if [ "$OAC_ID" = "None" ] || [ -z "$OAC_ID" ]; then
  OAC_ID="$(aws cloudfront create-origin-access-control \
    --origin-access-control-config \
    "Name=${OAC_NAME},SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
    --query "OriginAccessControl.Id" --output text)"
  echo "    created OAC: $OAC_ID"
else
  echo "    reusing OAC: $OAC_ID"
fi

# ============================================================
# 3. CloudFront distribution — reuse if we already made one
# ============================================================
echo "==> Ensuring CloudFront distribution (caller-ref: $CALLER_REF)"
DIST_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Origins.Items[0].Id=='s3-${BUCKET}'].Id | [0]" \
  --output text 2>/dev/null || echo "None")"

S3_DOMAIN="${BUCKET}.s3.${REGION}.amazonaws.com"

if [ "$DIST_ID" = "None" ] || [ -z "$DIST_ID" ]; then
  echo "==> Creating new distribution"
  DIST_CONFIG="$(cat <<JSON
{
  "CallerReference": "${CALLER_REF}-$(date +%s)",
  "Comment": "2048 game",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "Origins": {
    "Quantity": 1,
    "Items": [{
      "Id": "s3-${BUCKET}",
      "DomainName": "${S3_DOMAIN}",
      "OriginAccessControlId": "${OAC_ID}",
      "S3OriginConfig": { "OriginAccessIdentity": "" }
    }]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-${BUCKET}",
    "ViewerProtocolPolicy": "redirect-to-https",
    "Compress": true,
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6"
  },
  "CustomErrorResponses": {
    "Quantity": 2,
    "Items": [
      {"ErrorCode":403,"ResponseCode":"200","ResponsePagePath":"/index.html","ErrorCachingMinTTL":10},
      {"ErrorCode":404,"ResponseCode":"200","ResponsePagePath":"/index.html","ErrorCachingMinTTL":10}
    ]
  },
  "PriceClass": "PriceClass_100"
}
JSON
)"
  CREATE_OUT="$(aws cloudfront create-distribution --distribution-config "$DIST_CONFIG")"
  DIST_ID="$(echo "$CREATE_OUT" | jq -r '.Distribution.Id')"
  echo "    created distribution: $DIST_ID"
else
  echo "    reusing distribution: $DIST_ID"
fi

DIST_DOMAIN="$(aws cloudfront get-distribution --id "$DIST_ID" \
  --query "Distribution.DomainName" --output text)"
DIST_ARN="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}"

# ============================================================
# 4. Bucket policy: allow only this distribution (via OAC) to read
# ============================================================
echo "==> Applying bucket policy (CloudFront-only read access)"
POLICY="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontServicePrincipalReadOnly",
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${BUCKET}/*",
    "Condition": { "StringEquals": { "AWS:SourceArn": "${DIST_ARN}" } }
  }]
}
JSON
)"
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$POLICY"

# ============================================================
# 5. Upload site files with content types + cache headers
# ============================================================
echo "==> Uploading site files"
aws s3 cp "$SITE_DIR/index.html" "s3://$BUCKET/index.html" \
  --content-type "text/html; charset=utf-8" --cache-control "public, max-age=60"
aws s3 cp "$SITE_DIR/style.css" "s3://$BUCKET/style.css" \
  --content-type "text/css; charset=utf-8" --cache-control "public, max-age=3600"
aws s3 cp "$SITE_DIR/game.js" "s3://$BUCKET/game.js" \
  --content-type "application/javascript; charset=utf-8" --cache-control "public, max-age=3600"

# ============================================================
# 6. Invalidate the CloudFront cache
# ============================================================
echo "==> Invalidating CloudFront cache"
aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*" \
  --query "Invalidation.Id" --output text

echo ""
echo "============================================================"
echo " Deployment complete!"
echo "   Bucket:        $BUCKET"
echo "   Distribution:  $DIST_ID"
echo "   Live URL:      https://${DIST_DOMAIN}"
echo ""
echo " A brand-new distribution takes ~5-15 min to deploy globally."
echo " Check status: aws cloudfront get-distribution --id $DIST_ID \\"
echo "   --query 'Distribution.Status' --output text   (want: Deployed)"
echo "============================================================"
