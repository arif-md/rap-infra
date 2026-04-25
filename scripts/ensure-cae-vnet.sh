#!/bin/bash
###############################################################################
# Detects and removes a stranded Container Apps Environment (CAE) that exists
# without VNet configuration when VNet integration is required.
#
# Root cause: When `azd down` deletes the VNet before the CAE (or the CAE
# deletion fails), the CAE survives with vnetSubnetId=null. On the next
# provision, Bicep tries to set infrastructureSubnetId on the existing CAE
# which Azure rejects with ManagedEnvironmentCannotAddVnetToExistingEnv.
#
# Also handles CAEs still in ScheduledForDelete/Deleting state from a prior
# manual or automated delete, by waiting for them to fully disappear before
# allowing Bicep to proceed (prevents ManagedEnvironmentNotReadyForAppCreation).
###############################################################################

set -e

info()    { echo -e "\033[1;34mℹ $1\033[0m"; }
success() { echo -e "\033[1;32m✓ $1\033[0m"; }
warning() { echo -e "\033[1;33m⚠ $1\033[0m"; }
error()   { echo -e "\033[1;31m✗ $1\033[0m"; }
header()  { echo -e "\n\033[1;36m=== $1 ===\033[0m"; }

header "CAE VNet Guard"

# Only relevant when VNet integration is enabled
VNET_ENABLED="${ENABLE_VNET_INTEGRATION:-false}"
if [ "$VNET_ENABLED" != "true" ]; then
    success "VNet integration disabled — CAE VNet guard skipped."
    exit 0
fi

RG="${AZURE_RESOURCE_GROUP:-}"
ENV="${AZURE_ENV_NAME:-}"

if [ -z "$RG" ] || [ -z "$ENV" ]; then
    warning "AZURE_RESOURCE_GROUP or AZURE_ENV_NAME not set — skipping CAE VNet guard."
    exit 0
fi

###############################################################################
# wait_for_cae_gone: polls until the named CAE no longer appears in the list.
###############################################################################
wait_for_cae_gone() {
    local CAE_NAME="$1"
    local TIMEOUT=300   # 5 minutes
    local ELAPSED=0
    local INTERVAL=20

    info "Waiting for CAE '$CAE_NAME' to finish deleting (timeout ${TIMEOUT}s)..."
    while [ $ELAPSED -lt $TIMEOUT ]; do
        local STILL_EXISTS
        STILL_EXISTS=$(az containerapp env list -g "$RG" \
            --query "[?name=='$CAE_NAME'].name" -o tsv 2>/dev/null || true)
        if [ -z "$STILL_EXISTS" ]; then
            success "CAE '$CAE_NAME' is fully deleted."
            return 0
        fi
        info "  Still deleting... (${ELAPSED}s elapsed, checking again in ${INTERVAL}s)"
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done
    error "CAE '$CAE_NAME' did not finish deleting within ${TIMEOUT}s."
    return 1
}

###############################################################################
# Fetch all CAEs once and classify them.
###############################################################################
ALL_CAES=$(az containerapp env list -g "$RG" \
    --query "[].{name:name,state:properties.provisioningState,subnet:properties.vnetConfiguration.infrastructureSubnetId}" \
    -o json 2>/dev/null || echo "[]")

###############################################################################
# Step 1: Wait for any CAEs already in a deleting state (ScheduledForDelete /
# Deleting / Canceled). These are left from a prior manual delete or azd down.
# Prevents ManagedEnvironmentNotReadyForAppCreation.
###############################################################################
info "Checking for CAEs currently being deleted..."

DELETING_CAES=$(echo "$ALL_CAES" | python3 -c "
import json, sys
caes = json.load(sys.stdin)
for c in caes:
    if c.get('state','') in ('ScheduledForDelete','Deleting','Canceled'):
        print(c['name'])
" 2>/dev/null || true)

FOUND_DELETING=false
while IFS= read -r CAE_NAME; do
    [ -z "$CAE_NAME" ] && continue
    FOUND_DELETING=true
    warning "CAE '$CAE_NAME' is in state '$(echo "$ALL_CAES" | python3 -c "import json,sys; [print(c['state']) for c in json.load(sys.stdin) if c['name']=='$CAE_NAME']" 2>/dev/null)' — waiting for it to disappear..."
    wait_for_cae_gone "$CAE_NAME"
done <<< "$DELETING_CAES"

# Re-query if we waited for anything
if [ "$FOUND_DELETING" = "true" ]; then
    ALL_CAES=$(az containerapp env list -g "$RG" \
        --query "[].{name:name,state:properties.provisioningState,subnet:properties.vnetConfiguration.infrastructureSubnetId}" \
        -o json 2>/dev/null || echo "[]")
fi

###############################################################################
# Step 2: Detect stranded CAEs (Succeeded but no VNet subnet) and delete them.
###############################################################################
info "Checking for stranded CAE (Succeeded but no VNet config)..."

STRANDED_CAES=$(echo "$ALL_CAES" | python3 -c "
import json, sys
caes = json.load(sys.stdin)
for c in caes:
    if c.get('state') == 'Succeeded' and not c.get('subnet'):
        print(c['name'])
" 2>/dev/null || true)

if [ -z "$STRANDED_CAES" ]; then
    success "No stranded CAE found."
    exit 0
fi

while IFS= read -r CAE_NAME; do
    [ -z "$CAE_NAME" ] && continue
    warning "Found stranded CAE '$CAE_NAME' (no VNet config) — deleting so Bicep can recreate with VNet."

    # Container Apps must be deleted before the environment can be deleted.
    CAE_ID=$(az containerapp env show -g "$RG" -n "$CAE_NAME" --query id -o tsv 2>/dev/null || true)

    if [ -n "$CAE_ID" ]; then
        info "Deleting container apps in '$CAE_NAME' before removing the environment..."
        APPS=$(az containerapp list -g "$RG" \
            --query "[?properties.managedEnvironmentId=='$CAE_ID'].name" \
            -o tsv 2>/dev/null || true)

        while IFS= read -r APP_NAME; do
            [ -z "$APP_NAME" ] && continue
            info "  Deleting container app '$APP_NAME'..."
            az containerapp delete -g "$RG" -n "$APP_NAME" --yes 2>&1 \
                && success "  Deleted '$APP_NAME'." \
                || { error "  Failed to delete '$APP_NAME'."; exit 1; }
        done <<< "$APPS"
    fi

    warning "Deleting stranded CAE '$CAE_NAME'. All apps will be recreated by Bicep."
    az containerapp env delete -g "$RG" -n "$CAE_NAME" --yes 2>&1 \
        || { error "Failed to delete stranded CAE '$CAE_NAME'."; exit 1; }

    wait_for_cae_gone "$CAE_NAME"
done <<< "$STRANDED_CAES"

success "CAE VNet guard complete."
