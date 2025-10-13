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

# Optional: operator may provide the ACR resource group; otherwise we'll discover it subscription-wide
ACR_LOCATION=""
if [ -n "$AZURE_ACR_RESOURCE_GROUP" ]; then
  ACR_LOCATION=$(az group show -n "$AZURE_ACR_RESOURCE_GROUP" --query location -o tsv 2>/dev/null || true)
fi

# Ensure resource group exists (do not create it)
if ! az group show -n "$AZURE_RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "Resource group '$AZURE_RESOURCE_GROUP' not found. Set AZURE_RESOURCE_GROUP to an existing RG (azd env set AZURE_RESOURCE_GROUP <name>) or pre-create it." >&2
  exit 1
fi

# Permissions preflight: verify required roles on target resource group for ACR create and role assignment
SUB_ID="$(az account show --query id -o tsv 2>/dev/null || true)"
ASSIGNEE="$(az account show --query user.name -o tsv 2>/dev/null || true)"
TARGET_RG="$AZURE_ACR_RESOURCE_GROUP"
if [ -z "$TARGET_RG" ]; then TARGET_RG="$AZURE_RESOURCE_GROUP"; fi

# Ensure target RG exists and get its location
if ! az group show -n "$TARGET_RG" >/dev/null 2>&1; then
  echo "[preflight] Target ACR resource group '$TARGET_RG' not found. Set AZURE_ACR_RESOURCE_GROUP to an existing RG or create it." >&2
  exit 1
fi

if [ -n "$SUB_ID" ] && [ -n "$ASSIGNEE" ]; then
  ROLES=$(az role assignment list --assignee "$ASSIGNEE" --scope "/subscriptions/$SUB_ID/resourceGroups/$TARGET_RG" --include-inherited --query "[].roleDefinitionName" -o tsv 2>/dev/null || true)
  if [ -n "$ROLES" ]; then
    echo "[preflight] Roles for principal '$ASSIGNEE' at RG '$TARGET_RG': $(echo "$ROLES" | tr '\n' ', ' | sed 's/, $//')"
    echo "$ROLES" | grep -Eiq '^(Owner|Contributor)$|\s(Owner|Contributor)\s' || {
      echo "[preflight][ERROR] Missing Contributor or Owner on resource group '$TARGET_RG'. This is required to create or update ACR and related resources." >&2
      echo "[preflight][HINT] Grant 'Contributor' (minimum) or 'Owner' at scope: /subscriptions/$SUB_ID/resourceGroups/$TARGET_RG" >&2
      exit 1
    }
    echo "$ROLES" | grep -Eiq 'Owner|User Access Administrator' || {
      echo "[preflight][ERROR] Missing permission to create role assignments in RG '$TARGET_RG'." >&2
      echo "[preflight][DETAIL] The deployment assigns AcrPull to the app's managed identity; this requires 'Owner' or 'User Access Administrator' on the ACR's resource group." >&2
      echo "[preflight][HINT] Grant 'Owner' or 'User Access Administrator' at: /subscriptions/$SUB_ID/resourceGroups/$TARGET_RG" >&2
      exit 1
    }
  else
    echo "[preflight][WARN] Could not read role assignments at scope '/subscriptions/$SUB_ID/resourceGroups/$TARGET_RG'. Ensure your principal has permission to read role assignments. Continuing, but operations may fail due to insufficient permissions." >&2
  fi
else
  echo "[preflight][WARN] Unable to resolve subscription or principal for role checks; skipping permission preflight." >&2
fi

EXIST_JSON=$(az acr show -n "$AZURE_ACR_NAME" -o json 2>/dev/null || true)
if [ -n "$EXIST_JSON" ]; then
  EXIST_RG=$(printf '%s' "$EXIST_JSON" | jq -r '.resourceGroup // empty' 2>/dev/null || true)
  if [ -z "$EXIST_RG" ]; then
    EXIST_RG=$(printf '%s' "$EXIST_JSON" | jq -r '.id' 2>/dev/null | sed -n 's#.*/resourceGroups/\([^/]*\)/providers/.*#\1#p')
  fi
  echo "ACR '$AZURE_ACR_NAME' already exists in subscription in RG '${EXIST_RG:-unknown}'. Using existing registry."
  if [ -n "$EXIST_RG" ]; then
    azd env set AZURE_ACR_RESOURCE_GROUP "$EXIST_RG" >/dev/null || true
    # Re-check role assignment permissions on the actual ACR RG
    if [ -n "$SUB_ID" ] && [ -n "$ASSIGNEE" ]; then
      ROLES_ACR=$(az role assignment list --assignee "$ASSIGNEE" --scope "/subscriptions/$SUB_ID/resourceGroups/$EXIST_RG" --include-inherited --query "[].roleDefinitionName" -o tsv 2>/dev/null || true)
      if [ -n "$ROLES_ACR" ]; then
        echo "[preflight] Roles for principal '$ASSIGNEE' at ACR RG '$EXIST_RG': $(echo "$ROLES_ACR" | tr '\n' ', ' | sed 's/, $//')"
        echo "$ROLES_ACR" | grep -Eiq 'Owner|User Access Administrator' || {
          echo "[preflight][ERROR] Missing permission to create role assignments in ACR RG '$EXIST_RG'." >&2
          echo "[preflight][DETAIL] The deployment assigns AcrPull to the app's managed identity; this requires 'Owner' or 'User Access Administrator' on the ACR's resource group." >&2
          echo "[preflight][HINT] Grant 'Owner' or 'User Access Administrator' at: /subscriptions/$SUB_ID/resourceGroups/$EXIST_RG" >&2
          exit 1
        }
      else
        echo "[preflight][WARN] Could not read role assignments at scope '/subscriptions/$SUB_ID/resourceGroups/$EXIST_RG'. Ensure your principal has permission to read role assignments. Continuing, but operations may fail due to insufficient permissions." >&2
      fi
    fi
  fi
else
  # Not found via show; check name availability globally and create in preferred RG
  CHECK=$(az acr check-name -n "$AZURE_ACR_NAME" -o json 2>/dev/null || true)
  NAME_AVAILABLE=$(printf '%s' "$CHECK" | jq -r '.nameAvailable // empty' 2>/dev/null || true)
  REASON=$(printf '%s' "$CHECK" | jq -r '.reason // empty' 2>/dev/null || true)
  MESSAGE=$(printf '%s' "$CHECK" | jq -r '.message // empty' 2>/dev/null || true)
  TARGET_RG="$AZURE_ACR_RESOURCE_GROUP"
  if [ -z "$TARGET_RG" ]; then TARGET_RG="$AZURE_RESOURCE_GROUP"; fi
  if [ -z "$ACR_LOCATION" ]; then ACR_LOCATION=$(az group show -n "$TARGET_RG" --query location -o tsv 2>/dev/null || true); fi
  if [ "$NAME_AVAILABLE" = "true" ]; then
    echo "Creating ACR '$AZURE_ACR_NAME' in RG '$TARGET_RG'..."
    az acr create -n "$AZURE_ACR_NAME" -g "$TARGET_RG" -l "$ACR_LOCATION" --sku Standard --admin-enabled false --only-show-errors >/dev/null
    azd env set AZURE_ACR_RESOURCE_GROUP "$TARGET_RG" >/dev/null || true
  else
    if [ "$REASON" = "AlreadyExists" ]; then
      echo "[ensure-acr] ACR name '$AZURE_ACR_NAME' exists, but is not accessible in this subscription or with current credentials." >&2
      echo "[ensure-acr] Ensure your principal has Microsoft.ContainerRegistry/registries/read on the registry, or switch to the subscription where it exists." >&2
      exit 1
    else
      echo "[ensure-acr] ACR name '$AZURE_ACR_NAME' is not valid/available: ${MESSAGE}" >&2
      exit 1
    fi
  fi
fi

# If SERVICE_FRONTEND_IMAGE_NAME isn't set, try to resolve the latest image from ACR for this env
CURRENT_IMAGE="$(azd env get-value SERVICE_FRONTEND_IMAGE_NAME 2>/dev/null || true)"
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
  fi
fi
