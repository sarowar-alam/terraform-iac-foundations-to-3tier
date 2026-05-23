#!/bin/bash
# ==============================================================================
# bootstrap-s3-backend.sh — Create / Teardown Terraform Remote State S3 Bucket
#
# Usage:
#   bash bootstrap-s3-backend.sh            # create + configure bucket
#   bash bootstrap-s3-backend.sh --teardown # delete all versions + bucket
#
# Checks whether each configuration already exists before applying.
# Safe to run multiple times — fully idempotent.
# ==============================================================================
set -e

BUCKET="terraform-state-bmi-ostaddevops"
REGION="ap-south-1"
PROFILE="sarowar-ostad"

# Parse arguments
MODE="bootstrap"
for arg in "$@"; do
  case $arg in
    --teardown) MODE="teardown" ;;
    *) echo "Unknown argument: $arg"; echo "Usage: $0 [--teardown]"; exit 1 ;;
  esac
done

# ==============================================================================
# TEARDOWN — delete all object versions, delete markers, then the bucket
# ==============================================================================
if [ "$MODE" = "teardown" ]; then
  echo "=============================================="
  echo " S3 Backend TEARDOWN"
  echo " Bucket : $BUCKET"
  echo " Region : $REGION"
  echo "=============================================="
  echo ""

  # Check bucket exists first
  if ! aws s3api head-bucket --bucket "$BUCKET" --profile "$PROFILE" 2>/dev/null; then
    echo "  [SKIP] Bucket '$BUCKET' does not exist — nothing to delete."
    exit 0
  fi

  # Confirmation prompt
  echo "  WARNING: This will permanently delete ALL state files and the bucket."
  read -r -p "  Type the bucket name to confirm: " CONFIRM
  if [ "$CONFIRM" != "$BUCKET" ]; then
    echo "  [ABORT] Name did not match. Teardown cancelled."
    exit 1
  fi

  # ------------------------------------------------------------------
  # Step 1: Delete all object VERSIONS (versioned bucket won't delete
  #         with aws s3 rb unless all versions are removed first)
  # ------------------------------------------------------------------
  echo ""
  echo "[1/3] Deleting all object versions..."
  VERSIONS=$(aws s3api list-object-versions \
    --bucket "$BUCKET" \
    --profile "$PROFILE" \
    --query 'Versions[].{Key:Key,VersionId:VersionId}' \
    --output json 2>/dev/null)

  if [ "$VERSIONS" != "null" ] && [ "$VERSIONS" != "[]" ] && [ -n "$VERSIONS" ]; then
    echo "  [DELETE] Removing object versions..."
    echo "$VERSIONS" | \
      jq -c 'to_entries[] | {Objects: [{Key: .value.Key, VersionId: .value.VersionId}], Quiet: true}' | \
      while read -r BATCH; do
        aws s3api delete-objects \
          --bucket "$BUCKET" \
          --delete "$BATCH" \
          --profile "$PROFILE" > /dev/null
      done
    echo "  [OK] All object versions deleted."
  else
    echo "  [SKIP] No object versions found."
  fi

  # ------------------------------------------------------------------
  # Step 2: Delete all DELETE MARKERS
  # ------------------------------------------------------------------
  echo ""
  echo "[2/3] Deleting all delete markers..."
  MARKERS=$(aws s3api list-object-versions \
    --bucket "$BUCKET" \
    --profile "$PROFILE" \
    --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' \
    --output json 2>/dev/null)

  if [ "$MARKERS" != "null" ] && [ "$MARKERS" != "[]" ] && [ -n "$MARKERS" ]; then
    echo "  [DELETE] Removing delete markers..."
    echo "$MARKERS" | \
      jq -c 'to_entries[] | {Objects: [{Key: .value.Key, VersionId: .value.VersionId}], Quiet: true}' | \
      while read -r BATCH; do
        aws s3api delete-objects \
          --bucket "$BUCKET" \
          --delete "$BATCH" \
          --profile "$PROFILE" > /dev/null
      done
    echo "  [OK] All delete markers removed."
  else
    echo "  [SKIP] No delete markers found."
  fi

  # ------------------------------------------------------------------
  # Step 3: Delete the bucket
  # ------------------------------------------------------------------
  echo ""
  echo "[3/3] Deleting bucket..."
  aws s3api delete-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --profile "$PROFILE"
  echo "  [OK] Bucket '$BUCKET' deleted."

  echo ""
  echo "[DONE] Teardown complete."
  exit 0
fi

# ==============================================================================
# BOOTSTRAP — create and configure the bucket
# ==============================================================================
echo "=============================================="
echo " Terraform S3 Backend Bootstrap"
echo " Bucket : $BUCKET"
echo " Region : $REGION"
echo " Profile: $PROFILE"
echo "=============================================="

# ------------------------------------------------------------------------------
# 1. Check / Create bucket
# ------------------------------------------------------------------------------
echo ""
echo "[1/4] Checking if bucket exists..."
if aws s3api head-bucket --bucket "$BUCKET" --profile "$PROFILE" 2>/dev/null; then
  echo "  [SKIP] Bucket '$BUCKET' already exists."
else
  echo "  [CREATE] Bucket not found — creating..."
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" \
    --profile "$PROFILE"
  echo "  [OK] Bucket created."
fi

# ------------------------------------------------------------------------------
# 2. Check / Enable versioning
# ------------------------------------------------------------------------------
echo ""
echo "[2/4] Checking versioning..."
VERSIONING_STATUS=$(aws s3api get-bucket-versioning \
  --bucket "$BUCKET" \
  --profile "$PROFILE" \
  --query "Status" \
  --output text 2>/dev/null || echo "None")

if [ "$VERSIONING_STATUS" = "Enabled" ]; then
  echo "  [SKIP] Versioning is already Enabled."
else
  echo "  [ENABLE] Versioning is '$VERSIONING_STATUS' — enabling..."
  aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled \
    --profile "$PROFILE"
  echo "  [OK] Versioning enabled."
fi

# ------------------------------------------------------------------------------
# 3. Check / Enable server-side encryption (AES256)
# ------------------------------------------------------------------------------
echo ""
echo "[3/4] Checking encryption..."
ENCRYPTION=$(aws s3api get-bucket-encryption \
  --bucket "$BUCKET" \
  --profile "$PROFILE" \
  --query "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm" \
  --output text 2>/dev/null || echo "None")

if [ "$ENCRYPTION" = "AES256" ] || [ "$ENCRYPTION" = "aws:kms" ]; then
  echo "  [SKIP] Encryption already configured ($ENCRYPTION)."
else
  echo "  [ENABLE] Encryption not found — applying AES256..."
  aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
    --profile "$PROFILE"
  echo "  [OK] AES256 encryption enabled."
fi

# ------------------------------------------------------------------------------
# 4. Check / Block public access
# ------------------------------------------------------------------------------
echo ""
echo "[4/4] Checking public access block..."
PUBLIC_BLOCK=$(aws s3api get-public-access-block \
  --bucket "$BUCKET" \
  --profile "$PROFILE" \
  --query "PublicAccessBlockConfiguration.BlockPublicAcls" \
  --output text 2>/dev/null || echo "None")

if [ "$PUBLIC_BLOCK" = "True" ] || [ "$PUBLIC_BLOCK" = "true" ]; then
  echo "  [SKIP] Public access block is already enabled."
else
  echo "  [ENABLE] Public access not blocked — applying..."
  aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
    --profile "$PROFILE"
  echo "  [OK] Public access blocked."
fi

# ------------------------------------------------------------------------------
# Summary — print live state of all configs from AWS
# ------------------------------------------------------------------------------
echo ""
echo "=============================================="
echo " Final Bucket Configuration"
echo "=============================================="
echo ""
printf "  %-28s" "Versioning:"
aws s3api get-bucket-versioning \
  --bucket "$BUCKET" --profile "$PROFILE" \
  --query "Status" --output text

printf "  %-28s" "Encryption:"
aws s3api get-bucket-encryption \
  --bucket "$BUCKET" --profile "$PROFILE" \
  --query "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm" \
  --output text

printf "  %-28s" "BlockPublicAcls:"
aws s3api get-public-access-block \
  --bucket "$BUCKET" --profile "$PROFILE" \
  --query "PublicAccessBlockConfiguration.BlockPublicAcls" \
  --output text

echo ""
echo "[DONE] Bucket '$BUCKET' is ready."
echo "       Next: terraform init"
echo ""
echo "Tip: to delete the bucket later, run:"
echo "     bash scripts/bootstrap-s3-backend.sh --teardown"
