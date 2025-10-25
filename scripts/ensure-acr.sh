#!/usr/bin/env sh
set -e

if [ -z "$AZURE_RESOURCE_GROUP" ]; then
  if [ -n "$AZURE_ENV_NAME" ]; then
    AZURE_RESOURCE_GROUP="rg-raptor-$AZURE_ENV_NAME"
    azd env set AZURE_RESOURCE_GROUP "$AZURE_RESOURCE_GROUP" >/dev/null
  else
    echo "AZURE_RESOURCE_GROUP not set and AZURE_ENV_NAME unavailable. Set AZURE_RESOURCE_GROUP via 'azd env set AZURE_RESOURCE_GROUP <name>'." >&2
    exit 1
  fi
fi

if [ -z "$AZURE_ACR_NAME" ]; then
  if [ -z "$AZURE_ENV_NAME" ]; then
    echo "AZURE_ACR_NAME not set and AZURE_ENV_NAME unavailable. Set AZURE_ACR_NAME via 'azd env set AZURE_ACR_NAME <acrName>'." >&2
    exit 1
  fi
  # derive a stable default from env name
  AZURE_ACR_NAME=$(echo "$AZURE_ENV_NAME-rap-acr" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-50)
  azd env set AZURE_ACR_NAME "$AZURE_ACR_NAME" >/dev/null
fi

LOCATION=$(az group show -n "$AZURE_RESOURCE_GROUP" --query location -o tsv 2>/dev/null || true)
if [ -z "$LOCATION" ]; then
  echo "Could not resolve location for resource group '$AZURE_RESOURCE_GROUP'." >&2
  exit 1
fi

# Ensure resource group exists (do not create it)
if ! az group show -n "$AZURE_RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "Resource group '$AZURE_RESOURCE_GROUP' not found. Set AZURE_RESOURCE_GROUP to an existing RG (azd env set AZURE_RESOURCE_GROUP <name>) or pre-create it." >&2
  exit 1
fi

# Prefer RG-scoped discovery when AZURE_ACR_RESOURCE_GROUP is provided; otherwise skip show and rely on name check
EXIST_JSON=""
if [ -n "$AZURE_ACR_RESOURCE_GROUP" ]; then
  EXIST_JSON=$(az acr show -n "$AZURE_ACR_NAME" -g "$AZURE_ACR_RESOURCE_GROUP" -o json 2>/dev/null || true)
fi
if [ -n "$EXIST_JSON" ]; then
  echo "ACR '$AZURE_ACR_NAME' found in RG '$AZURE_ACR_RESOURCE_GROUP'. Using existing registry."
else
  # Not found (or no RG provided); check if name is globally available
  CHECK=$(az acr check-name -n "$AZURE_ACR_NAME" -o json 2>/dev/null || true)
  NAME_AVAILABLE=$(printf '%s' "$CHECK" | jq -r '.nameAvailable // empty' 2>/dev/null || true)
  REASON=$(printf '%s' "$CHECK" | jq -r '.reason // empty' 2>/dev/null || true)
  MESSAGE=$(printf '%s' "$CHECK" | jq -r '.message // empty' 2>/dev/null || true)
  if [ "$NAME_AVAILABLE" = "true" ]; then
    TARGET_RG=${AZURE_ACR_RESOURCE_GROUP:-$AZURE_RESOURCE_GROUP}
    echo "Creating ACR '$AZURE_ACR_NAME' in RG '$TARGET_RG'..."
    RG_LOC=$(az group show -n "$TARGET_RG" --query location -o tsv 2>/dev/null || echo "$LOCATION")
    az acr create -n "$AZURE_ACR_NAME" -g "$TARGET_RG" -l "$RG_LOC" --sku Standard --admin-enabled false --only-show-errors >/dev/null
  else
    # Name is not available globally
    if [ "$REASON" = "AlreadyExists" ]; then
      echo "[ensure-acr][WARN] ACR name '$AZURE_ACR_NAME' exists but could not be discovered via 'az acr show' without specifying the ACR group name." >&2
      echo "[ensure-acr][HINT] If role assignment is required, set AZURE_ACR_RESOURCE_GROUP to the ACR's RG or ensure Reader on Microsoft.ContainerRegistry." >&2
      # proceed without discovery; image resolution below may still work if data-plane access is permitted
    else
      echo "[ensure-acr] ACR name '$AZURE_ACR_NAME' is not valid or not available: ${MESSAGE}" >&2
      exit 1
    fi
  fi
fi

# If SERVICE_FRONTEND_IMAGE_NAME isn't set, try to resolve the latest image from ACR for this env
RAW_IMAGE=$(azd env get-value SERVICE_FRONTEND_IMAGE_NAME 2>/dev/null || true)
# Use only first line, strip CR, and ignore azd 'ERROR:' output
CURRENT_IMAGE=$(printf '%s' "$RAW_IMAGE" | tr -d '\r' | head -n1)
if printf '%s' "$CURRENT_IMAGE" | grep -qi '^error:'; then CURRENT_IMAGE=""; fi
ACR_DOMAIN="${AZURE_ACR_NAME}.azurecr.io"
CURRENT_DOMAIN="${CURRENT_IMAGE%%/*}"
if [ -z "$CURRENT_IMAGE" ]; then
  REGISTRY="${AZURE_ACR_NAME}.azurecr.io"
  REPO="raptor/frontend-${AZURE_ENV_NAME}"
  echo "Attempting to resolve latest image from ACR: $REGISTRY/$REPO"
  DIGEST=$(az acr repository show-manifests -n "$AZURE_ACR_NAME" --repository "$REPO" --orderby time_desc --top 1 --query "[0].digest" -o tsv 2>/dev/null || true)
  if [ -n "$DIGEST" ]; then
    IMAGE="$REGISTRY/$REPO@$DIGEST"
    echo "Resolved ACR image: $IMAGE"
    azd env set SERVICE_FRONTEND_IMAGE_NAME "$IMAGE" >/dev/null
    azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT false >/dev/null
  else
    FALLBACK="mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
    echo "No image found in ACR repo '$REPO'. Using fallback public image: $FALLBACK"
    azd env set SERVICE_FRONTEND_IMAGE_NAME "$FALLBACK" >/dev/null
    azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT true >/dev/null
  fi
else
  if [ "$CURRENT_DOMAIN" != "$ACR_DOMAIN" ]; then
    # If a non-ACR (likely public) image was set earlier, try to upgrade to the latest ACR image if available
    REGISTRY="$ACR_DOMAIN"
    REPO="raptor/frontend-${AZURE_ENV_NAME}"
    echo "Current image domain '$CURRENT_DOMAIN' differs from ACR '$ACR_DOMAIN'. Checking ACR for newer image: $REGISTRY/$REPO"
    DIGEST=$(az acr repository show-manifests -n "$AZURE_ACR_NAME" --repository "$REPO" --orderby time_desc --top 1 --query "[0].digest" -o tsv 2>/dev/null || true)
    if [ -n "$DIGEST" ]; then
      IMAGE="$REGISTRY/$REPO@$DIGEST"
      echo "Switching to ACR image: $IMAGE"
      azd env set SERVICE_FRONTEND_IMAGE_NAME "$IMAGE" >/dev/null
      azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT false >/dev/null
    else
      echo "No ACR image found; keeping existing image: $CURRENT_IMAGE"
    fi
  else
    echo "SERVICE_FRONTEND_IMAGE_NAME already set to ACR image; leaving as-is."
    # Validate that the digest still exists (heal if pruned)
    REPO_PATH="${CURRENT_IMAGE#*/}"
    REPO_NAME="${REPO_PATH%@*}"
    DIGEST_PART="${CURRENT_IMAGE##*@}"
    if [ "$CURRENT_IMAGE" = "$DIGEST_PART" ]; then
      echo "Current image is not digest form (tag only); will attempt to resolve latest digest for repo $REPO_NAME"
      LATEST=$(az acr repository show-manifests -n "$AZURE_ACR_NAME" --repository "$REPO_NAME" --orderby time_desc --top 1 --query "[0].digest" -o tsv 2>/dev/null || true)
      if [ -n "$LATEST" ]; then
        HEALED_IMAGE="$ACR_DOMAIN/$REPO_NAME@$LATEST"
        echo "Resolved latest digest: $HEALED_IMAGE"
        azd env set SERVICE_FRONTEND_IMAGE_NAME "$HEALED_IMAGE" >/dev/null
        CURRENT_IMAGE="$HEALED_IMAGE"
      else
        echo "Could not resolve any digest for $REPO_NAME; leaving tag-based image as-is."
      fi
    else
      # Only check existence if digest form
      if [ -n "$REPO_NAME" ] && [ -n "$DIGEST_PART" ]; then
        echo "Validating digest exists in ACR: $AZURE_ACR_NAME / $REPO_NAME @ $DIGEST_PART"
        if ! az acr manifest show -n "$AZURE_ACR_NAME" --repository "$REPO_NAME" --name "$DIGEST_PART" >/dev/null 2>&1; then
          echo "[heal] Digest no longer present (likely purged): $DIGEST_PART"
          NEW_DIGEST=$(az acr repository show-manifests -n "$AZURE_ACR_NAME" --repository "$REPO_NAME" --orderby time_desc --top 1 --query "[0].digest" -o tsv 2>/dev/null || true)
          if [ -n "$NEW_DIGEST" ]; then
            HEALED_IMAGE="$ACR_DOMAIN/$REPO_NAME@$NEW_DIGEST"
            echo "[heal] Switching to latest available digest: $HEALED_IMAGE"
            azd env set SERVICE_FRONTEND_IMAGE_NAME "$HEALED_IMAGE" >/dev/null
            CURRENT_IMAGE="$HEALED_IMAGE"
          else
            FALLBACK="mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
            echo "[heal] No digests remain in repo; falling back to public image: $FALLBACK"
            azd env set SERVICE_FRONTEND_IMAGE_NAME "$FALLBACK" >/dev/null
            azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT true >/dev/null
          fi
        else
          echo "Digest is present; no healing required."
        fi
      fi
    fi
  fi
fi
