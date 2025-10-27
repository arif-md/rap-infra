#!/usr/bin/env bash
# Validation script: Check consistency between image sources and SKIP_ACR_PULL_ROLE_ASSIGNMENT
# This script is called from both local azd up and GitHub Actions workflows

set -euo pipefail

echo "🔍 Validating image vs ACR binding consistency..."

# Get environment variables
AZURE_ACR_NAME=$(azd env get-value AZURE_ACR_NAME 2>/dev/null || echo "")
FRONTEND_IMG=$(azd env get-value SERVICE_FRONTEND_IMAGE_NAME 2>/dev/null || echo "")
BACKEND_IMG=$(azd env get-value SERVICE_BACKEND_IMAGE_NAME 2>/dev/null || echo "")
SKIP=$(azd env get-value SKIP_ACR_PULL_ROLE_ASSIGNMENT 2>/dev/null || echo "true")

if [ -z "$AZURE_ACR_NAME" ]; then
  echo "⚠️  AZURE_ACR_NAME not set. Skipping validation."
  exit 0
fi

ACR_DOMAIN="${AZURE_ACR_NAME}.azurecr.io"

# Check if any image uses ACR
ANY_ACR_IMAGE=false
if [[ "$FRONTEND_IMG" == *"$ACR_DOMAIN"* ]]; then
  ANY_ACR_IMAGE=true
  echo "   Frontend uses ACR: $FRONTEND_IMG"
fi
if [[ "$BACKEND_IMG" == *"$ACR_DOMAIN"* ]]; then
  ANY_ACR_IMAGE=true
  echo "   Backend uses ACR: $BACKEND_IMG"
fi

# Validate consistency
if [ "$ANY_ACR_IMAGE" = "true" ] && [ "$SKIP" = "true" ]; then
  echo "❌ Inconsistent configuration detected!" >&2
  echo "   At least one service uses ACR ($ACR_DOMAIN)" >&2
  echo "   But SKIP_ACR_PULL_ROLE_ASSIGNMENT=true" >&2
  echo "   This will cause deployment failure - Container Apps won't be able to pull images." >&2
  echo "" >&2
  echo "   Fix: Run './scripts/resolve-images.sh' to recalculate the SKIP flag." >&2
  exit 1
fi

if [ "$ANY_ACR_IMAGE" = "false" ] && [ "$SKIP" = "false" ]; then
  echo "⚠️  Suboptimal configuration detected (non-fatal)" >&2
  echo "   No services use ACR (all use public/external images)" >&2
  echo "   But SKIP_ACR_PULL_ROLE_ASSIGNMENT=false" >&2
  echo "   This won't cause errors, but Bicep will create an unnecessary role assignment." >&2
  echo "" >&2
  echo "   Recommendation: Run './scripts/resolve-images.sh' to recalculate the SKIP flag." >&2
  # Don't exit with error - this is just a warning
fi

echo "✅ Image vs ACR binding validation passed."
echo "   SKIP_ACR_PULL_ROLE_ASSIGNMENT=$SKIP"
echo "   ACR images: $([[ "$ANY_ACR_IMAGE" = "true" ]] && echo "Yes" || echo "No")"
