#!/bin/bash
# update-containerapp-image.sh
#
# Fast-path image update for Azure Container Apps with intelligent ACR deletion resilience.
# This script safely updates a Container App's container image, handling scenarios where
# old images may have been deleted from ACR.
#
# USAGE:
#   ./update-containerapp-image.sh <app-name> <resource-group> <new-image> <acr-name> <acr-domain> [acr-resource-group]
#
# ARGUMENTS:
#   app-name           Container App name (e.g., "test-rap-fe")
#   resource-group     Resource group of the Container App (e.g., "rg-raptor-test")
#   new-image          New image with digest (e.g., "acr.azurecr.io/repo@sha256:...")
#   acr-name           ACR registry name (e.g., "ngraptortest")
#   acr-domain         ACR full domain (e.g., "ngraptortest.azurecr.io")
#   acr-resource-group (Optional) Resource group where the ACR lives.
#                      Pass when the ACR is in a different RG from the Container App.
#
# REQUIREMENTS:
#   - Container App must exist
#   - Azure CLI authenticated with Container Apps permissions
#   - New image must be in digest format (@sha256:...)
#   - ACR must be accessible (registry binding already configured)
#
# BEHAVIOR:
#   1. Ensures ACR registry binding is configured (calls ensure-acr-binding.sh)
#   2. Checks if currently deployed image still exists in ACR:
#      a. FAST PATH: Check by commit tag (raptor.lastCommit) - much faster
#      b. FALLBACK: Check by digest in manifest list - slower but thorough
#   3. If old image exists: Use direct update (az containerapp update)
#   4. If old image deleted: Use revision copy (bypasses old image validation)
#
# EXIT CODES:
#   0 - Success
#   1 - Error (prerequisites not met, update failed)
#
# PERFORMANCE:
#   - Tag-based check: ~1-2 seconds (single API call)
#   - Digest-based check: ~3-5 seconds (lists all manifests)
#   - Uses tag check first for optimal performance
#
# EXAMPLE:
#   ./update-containerapp-image.sh \
#     "test-rap-fe" \
#     "rg-raptor-test" \
#     "ngraptortest.azurecr.io/raptor/frontend-test@sha256:abc123..." \
#     "ngraptortest" \
#     "ngraptortest.azurecr.io"

set -euo pipefail

# ============================================================================
# ARGUMENT VALIDATION
# ============================================================================

if [ $# -lt 5 ] || [ $# -gt 6 ]; then
  echo "Error: Invalid number of arguments" >&2
  echo "Usage: $0 <app-name> <resource-group> <new-image> <acr-name> <acr-domain> [acr-resource-group]" >&2
  exit 1
fi

APP_NAME="$1"
RG="$2"
NEW_IMG="$3"
ACR_NAME="$4"
ACR_DOMAIN="$5"
ACR_RG="${6:-}"  # Optional: resource group where the ACR lives (may differ from Container App RG)

# ============================================================================
# PREREQUISITE CHECKS
# ============================================================================

# Validate new image format (strict for ACR, flexible for public)
DIGEST_PART="${NEW_IMG#*@}"
IMAGE_DOMAIN="${NEW_IMG%%/*}"

if [ "$NEW_IMG" = "$DIGEST_PART" ]; then
  # No digest found - check if it's an ACR image
  if [ "$IMAGE_DOMAIN" = "$ACR_DOMAIN" ]; then
    # ACR images MUST use digest for immutability and traceability
    echo "❌ Error: ACR image must be in digest format (image@sha256:...)" >&2
    echo "  Image: $NEW_IMG" >&2
    echo "  ACR images require digest-based deployment for immutability and promotion workflows" >&2
    exit 1
  else
    # Public images can use tags
    echo "⚠️  Warning: Public image using tag-based reference (no digest)" >&2
    echo "  Image: $NEW_IMG" >&2
    echo "  This is acceptable for public images, but digest form is recommended for consistency." >&2
  fi
fi

# Verify Container App exists
if ! az containerapp show -n "$APP_NAME" -g "$RG" >/dev/null 2>&1; then
  echo "❌ Error: Container App '$APP_NAME' not found in resource group '$RG'" >&2
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 Container App Image Update"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  App:    $APP_NAME"
echo "  RG:     $RG"
echo "  Image:  $NEW_IMG"
echo ""

# ============================================================================
# ENSURE ACR REGISTRY BINDING
# ============================================================================

echo "📋 Step 1: Ensure ACR registry binding"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

DOMAIN="${NEW_IMG%%/*}"
if [ "$DOMAIN" = "$ACR_DOMAIN" ]; then
  chmod +x "$(dirname "$0")/ensure-acr-binding.sh"
  if ! "$(dirname "$0")/ensure-acr-binding.sh" "$APP_NAME" "$RG" "$ACR_NAME" "$ACR_DOMAIN" ${ACR_RG:+"$ACR_RG"}; then
    echo "❌ Failed to ensure ACR binding" >&2
    exit 1
  fi
else
  echo "ℹ️  Image not from specified ACR, skipping registry binding"
fi

echo ""

# ============================================================================
# CHECK IF CURRENT IMAGE EXISTS IN ACR (ACR DELETION RESILIENCE)
# ============================================================================

echo "📋 Step 2: Check if currently deployed image exists in ACR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Get currently deployed image
CURRENT_IMG=$(az containerapp show -n "$APP_NAME" -g "$RG" --query "properties.template.containers[0].image" -o tsv 2>/dev/null || true)
USE_REVISION_COPY=false

if [ -z "$CURRENT_IMG" ]; then
  echo "ℹ️  No current image found (new deployment)"
elif ! echo "$CURRENT_IMG" | grep -q "@sha256:"; then
  echo "ℹ️  Current image is tag-based (not digest), skipping check"
else
  # Parse current image details
  CURRENT_DOMAIN="${CURRENT_IMG%%/*}"
  
  if ! echo "$CURRENT_DOMAIN" | grep -q ".azurecr.io$"; then
    echo "ℹ️  Current image is not from ACR, skipping check"
  else
    CURRENT_REG=$(echo "$CURRENT_DOMAIN" | sed 's/\.azurecr\.io$//')
    CURRENT_PATH="${CURRENT_IMG#*/}"
    CURRENT_REPO="${CURRENT_PATH%@*}"
    CURRENT_DIGEST="${CURRENT_IMG#*@}"
    
    echo "Currently deployed image:"
    echo "  Full:       $CURRENT_IMG"
    echo "  Registry:   $CURRENT_REG"
    echo "  Repository: $CURRENT_REPO"
    echo "  Digest:     ${CURRENT_DIGEST:0:19}..."
    echo ""
    
    # ========================================================================
    # PERFORMANCE OPTIMIZATION: Check by commit tag first (FAST PATH)
    # ========================================================================
    
    echo "🔍 Checking if image exists in ACR..."
    echo ""
    
    # Get commit tag from Container App metadata
    COMMIT_TAG=$(az containerapp show -n "$APP_NAME" -g "$RG" --query "tags.\"raptor.lastCommit\"" -o tsv 2>/dev/null || true)
    IMAGE_EXISTS=false
    
    if [ -n "$COMMIT_TAG" ] && [ "$COMMIT_TAG" != "null" ]; then
      echo "  Method 1: Check by commit tag (fast path)"
      echo "  → Commit tag: $COMMIT_TAG"
      
      # Query ACR for this specific tag (much faster than listing all manifests)
      # Try full hash first
      TAG_EXISTS=$(az acr repository show-tags -n "$CURRENT_REG" --repository "$CURRENT_REPO" --query "[?@=='$COMMIT_TAG'] | [0]" -o tsv 2>/dev/null || true)
      
      if [ -n "$TAG_EXISTS" ]; then
        echo "  ✅ Found image by full commit tag"
        IMAGE_EXISTS=true
      else
        # If full hash not found, try short hash (first 7-12 characters)
        # ACR tags may use short commit hashes (e.g., 56a1641fcafc instead of full 56a1641fcafce07eb66636bdc2c21dcadf81760a)
        SHORT_COMMIT="${COMMIT_TAG:0:12}"
        echo "  ⚠️  Full commit tag not found, trying short form: $SHORT_COMMIT"
        
        # Use starts_with filter to find tags beginning with short hash
        TAG_EXISTS=$(az acr repository show-tags -n "$CURRENT_REG" --repository "$CURRENT_REPO" --query "[?starts_with(@, '$SHORT_COMMIT')] | [0]" -o tsv 2>/dev/null || true)
        
        if [ -n "$TAG_EXISTS" ]; then
          echo "  ✅ Found image by short commit tag: $TAG_EXISTS"
          IMAGE_EXISTS=true
        else
          echo "  ⚠️  Commit tag not found in ACR (tried both full and short forms)"
        fi
      fi
      echo ""
    fi
    
    # ========================================================================
    # FALLBACK: Check by digest in manifest list (SLOW PATH)
    # ========================================================================
    
    if [ "$IMAGE_EXISTS" = "false" ]; then
      echo "  Method 2: Check by digest (fallback - slower)"
      
      # Skip repository existence check - it often fails due to permission issues
      # Go straight to manifest checking which is more reliable
      echo "  → Checking digest in manifest list..."
      
      DIGEST_CHECK_OUTPUT=$(az acr repository show-manifests -n "$CURRENT_REG" --repository "$CURRENT_REPO" --query "[?digest=='$CURRENT_DIGEST'].digest | [0]" -o tsv 2>&1 || true)
      
      # Check for errors in output
      if echo "$DIGEST_CHECK_OUTPUT" | grep -iq "ERROR\|MANIFEST_UNKNOWN\|not found"; then
        # Either repository doesn't exist or digest doesn't exist - both cases need revision copy
        if echo "$DIGEST_CHECK_OUTPUT" | grep -iq "MANIFEST_UNKNOWN\|not found"; then
          echo "  ❌ Repository or digest not found in ACR"
        else
          echo "  ⚠️  Cannot verify digest (may lack ACR data-plane permissions)"
        fi
        echo "  → Will use revision copy to bypass validation"
        USE_REVISION_COPY=true
      elif [ -n "$DIGEST_CHECK_OUTPUT" ] && [ "$DIGEST_CHECK_OUTPUT" != "null" ]; then
        # Found the digest
        echo "  ✅ Digest exists in ACR"
        IMAGE_EXISTS=true
      else
        # Empty result means digest not found
        echo "  ❌ Digest not found in ACR (image may have been deleted)"
        echo "  → Will use revision copy to bypass validation"
        USE_REVISION_COPY=true
      fi
      echo ""
    fi
  fi
fi

# ============================================================================
# UPDATE CONTAINER APP IMAGE
# ============================================================================

echo "📋 Step 3: Update Container App image"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$USE_REVISION_COPY" = "true" ]; then
  echo "Strategy: Revision Copy (bypasses old image validation)"
  echo ""
  
  # Get current revision name
  CURRENT_REVISION=$(az containerapp revision list -n "$APP_NAME" -g "$RG" --query "[0].name" -o tsv 2>/dev/null || true)
  
  if [ -n "$CURRENT_REVISION" ]; then
    echo "  Current revision: $CURRENT_REVISION"
    echo "  Creating new revision with updated image..."
    echo ""
    
    az containerapp revision copy \
      -n "$APP_NAME" \
      -g "$RG" \
      --from-revision "$CURRENT_REVISION" \
      --image "$NEW_IMG"
    
    echo ""
    echo "✅ Revision copy completed successfully"
  else
    echo "  ⚠️  Could not determine current revision"
    echo "  Falling back to direct update..."
    echo ""
    
    az containerapp update \
      -n "$APP_NAME" \
      -g "$RG" \
      --image "$NEW_IMG"
    
    echo ""
    echo "✅ Direct update completed successfully"
  fi
else
  echo "Strategy: Direct Update (old image exists in ACR)"
  echo ""
  
  az containerapp update \
    -n "$APP_NAME" \
    -g "$RG" \
    --image "$NEW_IMG"
  
  echo ""
  echo "✅ Direct update completed successfully"
fi

# ============================================================================
# ENSURE targetPort MATCHES SERVER_PORT (hello-world → real image transition)
# ============================================================================
# When provisioned with the hello-world placeholder, Bicep sets targetPort=80.
# After promoting a real backend image (e.g. Spring Boot on 8080), the port
# stays at 80 unless corrected here. A mismatch causes health probes to fail,
# the backend revision becomes unhealthy, and the HTTP Route Config falls
# through to the catch-all (frontend), returning the Angular SPA HTML instead
# of JSON. Checking SERVER_PORT covers the backend; the frontend has no
# SERVER_PORT env var, so its port is never touched.

echo "📋 Step 4: Verify ingress targetPort"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

CONFIGURED_PORT=$(az containerapp show -n "$APP_NAME" -g "$RG" \
  --query "properties.configuration.ingress.targetPort" -o tsv 2>/dev/null || true)
SERVER_PORT_ENV=$(az containerapp show -n "$APP_NAME" -g "$RG" \
  --query "properties.template.containers[0].env[?name=='SERVER_PORT'].value | [0]" \
  -o tsv 2>/dev/null || true)

if [ -n "$SERVER_PORT_ENV" ] && [ "${CONFIGURED_PORT:-}" != "$SERVER_PORT_ENV" ]; then
  echo "⚠️  targetPort ($CONFIGURED_PORT) ≠ SERVER_PORT ($SERVER_PORT_ENV) — updating..."
  az containerapp ingress update -n "$APP_NAME" -g "$RG" \
    --target-port "$SERVER_PORT_ENV" >/dev/null
  echo "✓ targetPort updated to $SERVER_PORT_ENV"
else
  echo "✓ targetPort (${CONFIGURED_PORT:-unknown}) is correct"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Container App image update complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit 0
