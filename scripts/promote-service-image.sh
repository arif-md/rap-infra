#!/bin/bash
# ============================================================================
# Promote Service Image - Generalized Image Promotion Between Environments
# ============================================================================
# 
# PURPOSE:
#   Generic script for promoting container images between environments
#   for any service (frontend, backend, or future services).
#
# USAGE:
#   ./promote-service-image.sh <service-key> <source-image> <target-env>
#
# PARAMETERS:
#   service-key    - Service identifier (e.g., "frontend", "backend", "api")
#                    Used to construct:
#                    - Container App name: {env}-rap-{suffix}
#                    - ACR repository: raptor/{service-key}-{env}
#   source-image   - Source image with digest to promote
#   target-env     - Target environment (e.g., "test", "train", "prod")
#
# ENVIRONMENT VARIABLES REQUIRED:
#   AZURE_RESOURCE_GROUP     - Target resource group
#   AZURE_ACR_NAME           - Target ACR name
#   AZURE_ACR_NAME_SRC       - Source ACR name (optional, defaults to target ACR)
#
# OUTPUTS:
#   Sets GitHub Actions output: didFastPath=true/false
#
# EXIT CODES:
#   0 - Success (promotion completed)
#   1 - Failure (caller should run full provision)
#
# EXAMPLES:
#   # Promote frontend from dev to test
#   export AZURE_RESOURCE_GROUP="rg-raptor-test"
#   export AZURE_ACR_NAME="ngraptortest"
#   ./promote-service-image.sh frontend \
#     "ngraptordev.azurecr.io/raptor/frontend-dev@sha256:abc..." test
#
#   # Promote backend from test to prod
#   ./promote-service-image.sh backend \
#     "ngraptortest.azurecr.io/raptor/backend-test@sha256:def..." prod
# ============================================================================

set -euo pipefail

# ============================================================================
# ARGUMENT VALIDATION
# ============================================================================

if [ $# -lt 3 ]; then
  echo "Usage: $0 <service-key> <source-image> <target-env>" >&2
  echo "" >&2
  echo "Examples:" >&2
  echo "  $0 frontend ngraptordev.azurecr.io/raptor/frontend-dev@sha256:... test" >&2
  echo "  $0 backend ngraptortest.azurecr.io/raptor/backend-test@sha256:... prod" >&2
  exit 1
fi

SERVICE_KEY="$1"
SRC_IMAGE="$2"
TARGET_ENV="$3"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 Promote Service Image"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Service:      $SERVICE_KEY"
echo "Source Image: $SRC_IMAGE"
echo "Target Env:   $TARGET_ENV"
echo ""

# ============================================================================
# VALIDATE REQUIRED ENVIRONMENT VARIABLES
# ============================================================================

MISSING_VARS=()

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
# PARSE SOURCE IMAGE
# ============================================================================

echo "📋 Parsing source image..."

# Extract source ACR, repository, and digest
SRC_DOMAIN="${SRC_IMAGE%%/*}"
SRC_ACR=$(echo "$SRC_DOMAIN" | sed 's/\.azurecr\.io$//')
SRC_PATH="${SRC_IMAGE#*/}"
SRC_REPO="${SRC_PATH%@*}"
SRC_DIGEST="${SRC_IMAGE#*@}"

# Determine source ACR name (prefer env var, fallback to parsed)
AZURE_ACR_NAME_SRC="${AZURE_ACR_NAME_SRC:-$SRC_ACR}"

echo "  Source ACR:    $AZURE_ACR_NAME_SRC"
echo "  Source Repo:   $SRC_REPO"
echo "  Source Digest: ${SRC_DIGEST:0:19}..."
echo ""

# ============================================================================
# CONSTRUCT TARGET VALUES
# ============================================================================

echo "📋 Constructing target values..."

# Target repository naming: raptor/{service-key}-{env}
# Example: raptor/frontend-test, raptor/backend-prod
TARGET_REPO="raptor/${SERVICE_KEY}-${TARGET_ENV}"

# Target ACR domain
TARGET_ACR_DOMAIN="${AZURE_ACR_NAME}.azurecr.io"

# Generate promotion tag (timestamp-based for uniqueness)
PROMOTION_TAG="promoted-$(date +%s%3N)"

# New image reference
NEW_IMAGE="${TARGET_ACR_DOMAIN}/${TARGET_REPO}@${SRC_DIGEST}"

# Container App naming convention
case "$SERVICE_KEY" in
  frontend)
    SERVICE_SUFFIX="fe"
    ;;
  backend)
    SERVICE_SUFFIX="be"
    ;;
  processes)
    SERVICE_SUFFIX="proc"
    ;;
  *)
    SERVICE_SUFFIX=$(echo "$SERVICE_KEY" | cut -c1-3)
    ;;
esac

APP_NAME="${TARGET_ENV}-rap-${SERVICE_SUFFIX}"

echo "  Target ACR:    $AZURE_ACR_NAME"
echo "  Target Repo:   $TARGET_REPO"
echo "  Target Domain: $TARGET_ACR_DOMAIN"
echo "  Promotion Tag: $PROMOTION_TAG"
echo "  New Image:     $NEW_IMAGE"
echo "  Container App: $APP_NAME"
echo ""

# ============================================================================
# IMPORT IMAGE TO TARGET ACR
# ============================================================================

echo "📥 Importing image to target ACR..."
echo ""

# Check if target repository exists, create if not
if ! az acr repository show -n "$AZURE_ACR_NAME" --repository "$TARGET_REPO" >/dev/null 2>&1; then
  echo "  ℹ️  Target repository doesn't exist yet (will be created during import)"
fi

# Import image from source ACR to target ACR
# This copies the manifest and all layers
echo "  Importing: $SRC_ACR/$SRC_REPO@${SRC_DIGEST:0:19}..."
echo "         To: $AZURE_ACR_NAME/$TARGET_REPO"

if az acr import \
  --name "$AZURE_ACR_NAME" \
  --source "${AZURE_ACR_NAME_SRC}.azurecr.io/${SRC_REPO}@${SRC_DIGEST}" \
  --image "${TARGET_REPO}@${SRC_DIGEST}" \
  --force \
  >/dev/null 2>&1; then
  echo "  ✅ Image imported successfully"
else
  echo "  ❌ Failed to import image" >&2
  echo "didFastPath=false" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  exit 1
fi

# Tag the imported manifest with promotion tag for tracking
echo ""
echo "  🏷️  Tagging with: $PROMOTION_TAG"
if az acr repository untag \
  --name "$AZURE_ACR_NAME" \
  --image "${TARGET_REPO}:${PROMOTION_TAG}" \
  2>/dev/null || true; then
  :  # Tag existed, removed
fi

az acr import \
  --name "$AZURE_ACR_NAME" \
  --source "${TARGET_ACR_DOMAIN}/${TARGET_REPO}@${SRC_DIGEST}" \
  --image "${TARGET_REPO}:${PROMOTION_TAG}" \
  --no-wait \
  >/dev/null 2>&1 || true

echo "  ✅ Promotion tag applied"
echo ""

# ============================================================================
# UPDATE CONTAINER APP
# ============================================================================

echo "🚀 Updating Container App with promoted image..."
echo ""

# Call the generalized update-containerapp-image.sh script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$SCRIPT_DIR/update-containerapp-image.sh"

if "$SCRIPT_DIR/update-containerapp-image.sh" \
  "$APP_NAME" \
  "$AZURE_RESOURCE_GROUP" \
  "$NEW_IMAGE" \
  "$AZURE_ACR_NAME" \
  "$TARGET_ACR_DOMAIN"; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✅ Service image promotion successful!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "📊 Summary:"
  echo "  Service:    $SERVICE_KEY"
  echo "  Target Env: $TARGET_ENV"
  echo "  Image:      $NEW_IMAGE"
  echo "  App:        $APP_NAME"
  echo ""
  echo "didFastPath=true" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  exit 0
else
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "❌ Promotion failed"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Caller should fall back to full provision."
  echo "didFastPath=false" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  exit 1
fi
