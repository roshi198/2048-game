#!/usr/bin/env bash
#
# Deploy the 2048 game to AWS (S3 + CloudFront).
#
# Prerequisites:
#   - AWS CLI v2 installed and configured (`aws configure`) with permissions for
#     CloudFormation, S3, and CloudFront.
#
# Usage:
#   ./deploy.sh                 # uses defaults below
#   STACK_NAME=my-2048 REGION=us-east-1 ./deploy.sh
#
set -euo pipefail

# -------- Config (override via environment variables) --------
STACK_NAME="${STACK_NAME:-game-2048}"
REGION="${REGION:-us-east-1}"
TEMPLATE="infra/cloudformation.yaml"
# Files to upload (the static site)
SITE_FILES=(index.html style.css game.js)

echo "==> Deploying stack '$STACK_NAME' in region '$REGION'"

# -------- 1. Create / update the infrastructure --------
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --region "$REGION" \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset

# -------- 2. Read stack outputs --------
get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

BUCKET="$(get_output BucketNameOut)"
DIST_ID="$(get_output DistributionId)"
SITE_URL="$(get_output SiteURL)"

echo "==> Bucket:        $BUCKET"
echo "==> Distribution:  $DIST_ID"

# -------- 3. Upload site files --------
echo "==> Uploading site files to s3://$BUCKET/"

# HTML: short cache so updates show up quickly
aws s3 cp index.html "s3://$BUCKET/index.html" \
  --region "$REGION" \
  --content-type "text/html; charset=utf-8" \
  --cache-control "public, max-age=60"

# CSS / JS: can be cached (bust via CloudFront invalidation on deploy)
aws s3 cp style.css "s3://$BUCKET/style.css" \
  --region "$REGION" \
  --content-type "text/css; charset=utf-8" \
  --cache-control "public, max-age=3600"

aws s3 cp game.js "s3://$BUCKET/game.js" \
  --region "$REGION" \
  --content-type "application/javascript; charset=utf-8" \
  --cache-control "public, max-age=3600"

# -------- 4. Invalidate CloudFront cache --------
echo "==> Invalidating CloudFront cache"
aws cloudfront create-invalidation \
  --distribution-id "$DIST_ID" \
  --paths "/*" \
  --region "$REGION" \
  --query "Invalidation.Id" \
  --output text

echo ""
echo "============================================================"
echo " Deployment complete!"
echo " Your game is live at:"
echo "   $SITE_URL"
echo ""
echo " Note: a brand-new CloudFront distribution can take"
echo " 5-15 minutes to fully propagate the first time."
echo "============================================================"
