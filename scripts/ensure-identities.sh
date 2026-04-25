#!/bin/bash
###############################################################################
# Pre-provisions all managed identities and grants the backend identity Key
# Vault access BEFORE the main Bicep deployment runs.
#
# WHY THIS EXISTS
# ---------------
# Container Apps validates Key Vault URL secret references at deployment time
# by calling the KV data plane using the managed identity. If the identity is
# freshly created in the same Bicep deployment, the KV access policy may not
# have propagated to the KV data plane yet when Container Apps runs that
# validation, causing:
#
#   "unable to fetch secret 'jwt-secret' using Managed identity"
#
# This race condition only manifests on a clean azd up (after azd down) when
# no VNet is configured — with VNet the parallel subnet/DNS/PE resources add
# enough time that propagation completes before Container Apps deploys.
#
# SOLUTION
# --------
# Pre-create ALL managed identities (same names Bicep will use) here, minutes
# before Bicep runs. Bicep references them as 'existing' resources (they are
# therefore excluded from the deployment stack and survive 'azd down').
# This script also grants the backend identity KV secret access and polls the
# ARM control plane to confirm propagation before returning.
#
# NAMING
# ------
# Identity names are computed here using SHA-256 over (subscriptionId +
# resourceGroup + environmentName), then exported as azd env vars. main.bicep
# reads these via override parameters (same pattern as KEY_VAULT_NAME). This
# makes identity names unique per resource group, satisfying the design rule
# that each environment lives in its own RG.
#
# NOTE: Bicep's native uniqueString() uses a different (base36) algorithm than
# SHA-256. The script formula is the authoritative source for identity names;
# Bicep defers to whatever this script exports.
###############################################################################

set -e

info()    { echo -e "\033[1;34mℹ $1\033[0m" >&2; }
success() { echo -e "\033[1;32m✓ $1\033[0m" >&2; }
warning() { echo -e "\033[1;33m⚠ $1\033[0m" >&2; }
error()   { echo -e "\033[1;31m✗ $1\033[0m" >&2; }

ENVIRONMENT_NAME="${AZURE_ENV_NAME}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP}"
LOCATION="${AZURE_LOCATION}"
KEY_VAULT_NAME="${KEY_VAULT_NAME:-}"

if [ -z "$ENVIRONMENT_NAME" ]; then
  error "AZURE_ENV_NAME is not set"; exit 1
fi
if [ -z "$RESOURCE_GROUP" ]; then
  error "AZURE_RESOURCE_GROUP is not set"; exit 1
fi
if [ -z "$LOCATION" ]; then
  error "AZURE_LOCATION is not set"; exit 1
fi

# ---------------------------------------------------------------------------
# Compute identity resource token.
#
# Formula: sha256(subscriptionId + resourceGroupName + environmentName)
# truncated to 13 hex chars. Including the resource group ensures identity
# names are unique per RG (each environment lives in its own RG).
#
# Note: this hash deliberately differs from Bicep's uniqueString (base36).
# Identity names are exported to azd env and Bicep reads them as parameters,
# so Bicep does not re-derive them independently.
# ---------------------------------------------------------------------------
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
UNIQUE_STRING=$(printf '%s' "${SUBSCRIPTION_ID}${RESOURCE_GROUP}${ENVIRONMENT_NAME}" | sha256sum | cut -c1-13)
RESOURCE_TOKEN="${ENVIRONMENT_NAME}-${UNIQUE_STRING}"

# Read the managed identity prefix from abbreviations.json (same source as main.bicep)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
ID_PREFIX=$(jq -r '.managedIdentityUserAssignedIdentities' "$INFRA_DIR/abbreviations.json" 2>/dev/null || echo "id-")

# Derive all four identity names using the same prefix as main.bicep
BACKEND_IDENTITY_NAME="${ID_PREFIX}backend-${RESOURCE_TOKEN}"
FRONTEND_IDENTITY_NAME="${ID_PREFIX}frontend-${RESOURCE_TOKEN}"
PROCESSES_IDENTITY_NAME="${ID_PREFIX}processes-${RESOURCE_TOKEN}"
SQL_ADMIN_IDENTITY_NAME="${ID_PREFIX}sqladmin-${RESOURCE_TOKEN}"

info "Environment    : $ENVIRONMENT_NAME"
info "Resource group : $RESOURCE_GROUP"
info "Identity token : $RESOURCE_TOKEN"
info "Backend        : $BACKEND_IDENTITY_NAME"
info "Frontend       : $FRONTEND_IDENTITY_NAME"
info "Processes      : $PROCESSES_IDENTITY_NAME"
info "SQL admin      : $SQL_ADMIN_IDENTITY_NAME"

# ---------------------------------------------------------------------------
# Helper: create a managed identity if it does not already exist.
# Returns the principal ID via stdout.
# ---------------------------------------------------------------------------
ensure_identity() {
  local identity_name="$1"
  local label="$2"

  if az identity show \
      --name "$identity_name" \
      --resource-group "$RESOURCE_GROUP" \
      --output none 2>/dev/null; then
    success "$label identity '$identity_name' already exists"
  else
    info "Creating $label managed identity '$identity_name'..."
    az identity create \
      --name "$identity_name" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$LOCATION" \
      --output none
    success "$label identity created"
  fi

  az identity show \
    --name "$identity_name" \
    --resource-group "$RESOURCE_GROUP" \
    --query principalId -o tsv
}

# ---------------------------------------------------------------------------
# Create all identities and capture principal IDs
# ---------------------------------------------------------------------------
BACKEND_PRINCIPAL_ID=$(ensure_identity "$BACKEND_IDENTITY_NAME" "Backend")
FRONTEND_PRINCIPAL_ID=$(ensure_identity "$FRONTEND_IDENTITY_NAME" "Frontend")
PROCESSES_PRINCIPAL_ID=$(ensure_identity "$PROCESSES_IDENTITY_NAME" "Processes")

# SQL admin identity is only needed when SQL Database is enabled
ENABLE_SQL="${ENABLE_SQL_DATABASE:-true}"
if [ "$ENABLE_SQL" != "false" ]; then
  SQL_ADMIN_PRINCIPAL_ID=$(ensure_identity "$SQL_ADMIN_IDENTITY_NAME" "SQL admin")
else
  info "SQL Database disabled — skipping SQL admin identity creation"
fi

# ---------------------------------------------------------------------------
# Export identity names to azd environment.
# These are read by main.bicep via main.parameters.json override parameters,
# so Bicep uses exactly the same names as were created above.
# ---------------------------------------------------------------------------
info "Exporting identity names to azd environment..."
azd env set BACKEND_IDENTITY_NAME  "$BACKEND_IDENTITY_NAME"  >/dev/null
azd env set FRONTEND_IDENTITY_NAME "$FRONTEND_IDENTITY_NAME" >/dev/null
azd env set PROCESSES_IDENTITY_NAME "$PROCESSES_IDENTITY_NAME" >/dev/null
if [ "$ENABLE_SQL" != "false" ]; then
  azd env set SQL_ADMIN_IDENTITY_NAME "$SQL_ADMIN_IDENTITY_NAME" >/dev/null
fi
success "Identity names exported"

# ---------------------------------------------------------------------------
# Resolve Key Vault name (must have been set by ensure-keyvault.sh, which
# runs earlier in the pre-provision hook chain)
# ---------------------------------------------------------------------------
if [ -z "$KEY_VAULT_NAME" ]; then
  # Fallback: derive using same formula as ensure-keyvault.sh
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  INFRA_DIR="$(dirname "$SCRIPT_DIR")"
  KV_PREFIX=$(jq -r '.keyVaultVaults' "$INFRA_DIR/abbreviations.json" 2>/dev/null || echo "kv-")
  # ensure-keyvault.sh uses md5sum with subscription+envname (no RG) — replicate that here
  KV_UNIQUE=$(printf '%s' "${SUBSCRIPTION_ID}${ENVIRONMENT_NAME}" | md5sum | cut -c1-13)
  KV_TOKEN="${ENVIRONMENT_NAME}-${KV_UNIQUE}"
  KEY_VAULT_NAME="${KV_PREFIX}${KV_TOKEN}-v10"
  warning "KEY_VAULT_NAME not set — derived fallback: $KEY_VAULT_NAME"
else
  info "Using Key Vault: $KEY_VAULT_NAME"
fi

# ---------------------------------------------------------------------------
# Verify Key Vault exists before attempting policy operations
# ---------------------------------------------------------------------------
if ! az keyvault show --name "$KEY_VAULT_NAME" --resource-group "$RESOURCE_GROUP" --output none 2>/dev/null; then
  warning "Key Vault '$KEY_VAULT_NAME' not found in '$RESOURCE_GROUP'"
  warning "KV access policy cannot be set — Container Apps may fail to read secrets"
  warning "Ensure ensure-keyvault.sh ran successfully before this step"
  exit 0
fi

# ---------------------------------------------------------------------------
# Grant backend identity Key Vault secret access (get + list).
# Only the backend Container App reads secrets from KV; frontend and processes
# do not. The SQL admin identity does not need KV access.
# Idempotent: re-running overwrites with the same permissions.
# ---------------------------------------------------------------------------
info "Granting Key Vault secret access (get, list) to backend identity..."
info "  Identity name : $BACKEND_IDENTITY_NAME"
info "  Principal ID  : $BACKEND_PRINCIPAL_ID"
if az keyvault set-policy \
    --name "$KEY_VAULT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --object-id "$BACKEND_PRINCIPAL_ID" \
    --secret-permissions get list \
    --output none; then
  success "Key Vault access policy set for '$BACKEND_IDENTITY_NAME'"
else
  error "Failed to set KV access policy for '$BACKEND_IDENTITY_NAME' (object-id: $BACKEND_PRINCIPAL_ID)"
  error "Check that the deploying principal has 'Key Vault Contributor' on '$RESOURCE_GROUP'"
  exit 1
fi

# ---------------------------------------------------------------------------
# Poll ARM control plane until the access policy entry is confirmed.
#
# WHY POLL INSTEAD OF SLEEP
# -------------------------
# We cannot verify KV *data-plane* propagation from outside the managed
# identity — that would require calling the KV REST endpoint as id-backend-*,
# which this script cannot do (it runs as the GitHub Actions SP / developer
# principal). However, polling the ARM control plane (az keyvault show →
# accessPolicies) confirms that Azure has committed the policy write. Once ARM
# confirms it, the KV data plane typically propagates within 5–10 seconds.
# A short fixed buffer after ARM confirmation is therefore far more reliable
# than a blind sleep, which starts the timer before ARM has even processed the
# write request.
# ---------------------------------------------------------------------------
info "Polling ARM control plane until access policy is confirmed..."
MAX_WAIT=120
INTERVAL=10
ELAPSED=0
CONFIRMED=false

while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  POLICY_CHECK=$(az keyvault show \
    --name "$KEY_VAULT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "properties.accessPolicies[?objectId=='${BACKEND_PRINCIPAL_ID}'].objectId" \
    -o tsv 2>/dev/null || true)

  if [ -n "$POLICY_CHECK" ]; then
    success "Access policy confirmed in ARM control plane (${ELAPSED}s elapsed)"
    CONFIRMED=true
    break
  fi

  info "  Policy not yet visible in ARM (${ELAPSED}s elapsed) — retrying in ${INTERVAL}s..."
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ "$CONFIRMED" = false ]; then
  error "Access policy not confirmed in ARM after ${MAX_WAIT}s"
  error "KV data-plane propagation cannot be guaranteed — aborting to prevent Container App deployment failure"
  exit 1
fi

# ---------------------------------------------------------------------------
# Fixed buffer: KV data plane finishes propagating after ARM confirmation.
# ARM marks the policy write as Succeeded; data plane typically syncs within
# 5–10 seconds. The 15-second buffer provides a safe margin.
# ---------------------------------------------------------------------------
info "Waiting 15 seconds for KV data plane to sync after ARM confirmation..."
sleep 15
success "Identity pre-provisioning complete"
