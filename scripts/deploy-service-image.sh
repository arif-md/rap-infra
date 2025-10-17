#!/bin/bash
# ============================================================================
# Deploy Service Image - Generalized Container App Image Deployment
# ============================================================================
# 
# PURPOSE:
#   Generic script for deploying/updating container images to Azure Container Apps
#   for any service (frontend, backend, or future services).
#
# USAGE:
#   ./deploy-service-image.sh <service-key> <environment>
#
# PARAMETERS:
#   service-key    - Service identifier (e.g., "frontend", "backend", "api")
#                    Used to construct:
#                    - Container App name: {env}-rap-{key}
#                    - Environment variable: SERVICE_{KEY}_IMAGE_NAME
#   environment    - Target environment name (e.g., "dev", "test", "train", "prod")
#
# ENVIRONMENT VARIABLES REQUIRED:
#   AZURE_ENV_NAME           - Azure environment name
#   AZURE_RESOURCE_GROUP     - Target resource group
#   AZURE_ACR_NAME           - Azure Container Registry name
#
# ENVIRONMENT VARIABLES (from azd env):
#   SERVICE_{KEY}_IMAGE_NAME - Full image with digest for the service
#
# OUTPUTS:
#   Sets GitHub Actions output: didFastPath=true/false
#
# EXIT CODES:
#   0 - Success (fast-path update completed)
#   1 - Failure or cannot fast-path (caller should run full provision)
#
# EXAMPLES:
#   # Deploy frontend service
#   ./deploy-service-image.sh frontend dev
#
#   # Deploy backend service
#   ./deploy-service-image.sh backend test
#
#   # Deploy API service
#   ./deploy-service-image.sh api prod
# ============================================================================

set -euo pipefail

# ============================================================================
# ARGUMENT VALIDATION
# ============================================================================

if [ $# -lt 2 ]; then
  echo "Usage: $0 <service-key> <environment>" >&2
  echo "" >&2
  echo "Examples:" >&2
  echo "  $0 frontend dev" >&2
  echo "  $0 backend test" >&2
  exit 1
fi

SERVICE_KEY="$1"
ENVIRONMENT="$2"

# Convert service key to uppercase for environment variable names
SERVICE_KEY_UPPER=$(echo "$SERVICE_KEY" | tr '[:lower:]' '[:upper:]')

# Construct environment variable name (e.g., SERVICE_FRONTEND_IMAGE_NAME)
IMAGE_ENV_VAR="SERVICE_${SERVICE_KEY_UPPER}_IMAGE_NAME"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Deploy Service Image"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Service:     $SERVICE_KEY"
echo "Environment: $ENVIRONMENT"
echo "Image Var:   $IMAGE_ENV_VAR"
echo ""

# ============================================================================
# VALIDATE REQUIRED ENVIRONMENT VARIABLES
# ============================================================================

MISSING_VARS=()

if [ -z "${AZURE_ENV_NAME:-}" ]; then
  MISSING_VARS+=("AZURE_ENV_NAME")
fi

if [ -z "${AZURE_RESOURCE_GROUP:-}" ]; then
  MISSING_VARS+=("AZURE_RESOURCE_GROUP")
fi

if [ -z "${AZURE_ACR_NAME:-}" ]; then
  MISSING_VARS+=("AZURE_ACR_NAME")
fi

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
  echo "❌ Missing required environment variables:" >&2
  for var in "${MISSING_VARS[@]}"; do
    echo "  - $var" >&2
  done
  echo "didFastPath=false" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  exit 1
fi

# ============================================================================
# CONSTRUCT SERVICE-SPECIFIC VALUES
# ============================================================================

# Container App naming convention: {env}-rap-{service-key}
# Example: dev-rap-fe, test-rap-backend, prod-rap-api
# Note: Use short form for frontend (fe) to maintain backward compatibility
case "$SERVICE_KEY" in
  frontend)
    SERVICE_SUFFIX="fe"
    ;;
  backend)
    SERVICE_SUFFIX="be"
    ;;
  *)
    # For other services, use first 2-3 characters
    SERVICE_SUFFIX=$(echo "$SERVICE_KEY" | cut -c1-3)
    ;;
esac

APP_NAME=$(echo "${AZURE_ENV_NAME}-rap-${SERVICE_SUFFIX}" | tr '[:upper:]' '[:lower:]')
ACR_DOMAIN="${AZURE_ACR_NAME}.azurecr.io"

echo "📋 Configuration:"
echo "  App Name:    $APP_NAME"
echo "  Resource Group: $AZURE_RESOURCE_GROUP"
echo "  ACR Name:    $AZURE_ACR_NAME"
echo "  ACR Domain:  $ACR_DOMAIN"
echo ""

# ============================================================================
# GET IMAGE FROM AZD ENVIRONMENT
# ============================================================================

echo "🔍 Retrieving image from azd environment..."
IMG=$(azd env get-value "$IMAGE_ENV_VAR" 2>/dev/null || true)

if [ -z "$IMG" ]; then
  echo "⚠️  No image configured in $IMAGE_ENV_VAR"
  echo "Cannot fast-path; full provision required."
  echo "didFastPath=false" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  exit 1
fi

echo "  Image: $IMG"
echo ""

# ============================================================================
# EARLY VALIDATION CHECKS
# ============================================================================

echo "✅ Pre-flight checks..."

# Check 1: Image must be in digest form
DIGEST_PART="${IMG#*@}"
if [ "$IMG" = "$DIGEST_PART" ]; then
  echo "⚠️  Image is not in digest form (no @sha256:...)"
  echo "Cannot fast-path; full provision required."
  echo "didFastPath=false" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  exit 1
fi
echo "  ✓ Image is in digest form"

# Check 2: Container App must exist
if ! az containerapp show -n "$APP_NAME" -g "$AZURE_RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "⚠️  Container App '$APP_NAME' does not exist"
  echo "Cannot fast-path; full provision required."
  echo "didFastPath=false" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  exit 1
fi
echo "  ✓ Container App exists"
echo ""

# ============================================================================
# EXECUTE IMAGE UPDATE
# ============================================================================

echo "🚀 Executing image update..."
echo ""

# Call the generalized update-containerapp-image.sh script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$SCRIPT_DIR/update-containerapp-image.sh"

if "$SCRIPT_DIR/update-containerapp-image.sh" "$APP_NAME" "$AZURE_RESOURCE_GROUP" "$IMG" "$AZURE_ACR_NAME" "$ACR_DOMAIN"; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✅ Service image deployment successful!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "didFastPath=true" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  exit 0
else
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "❌ Fast-path update failed"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Caller should fall back to full provision (azd up)."
  echo "didFastPath=false" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  exit 1
fi
