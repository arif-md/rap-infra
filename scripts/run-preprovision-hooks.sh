#!/bin/bash

###############################################################################
# Runs all pre-provision hooks for Azure deployment
# Orchestrates the execution of all pre-provision scripts in the correct order.
# Fails fast if any script returns a non-zero exit code.
###############################################################################

set -e

# Color output functions
info() { echo -e "\033[1;34mℹ $1\033[0m"; }
success() { echo -e "\033[1;32m✓ $1\033[0m"; }
error() { echo -e "\033[1;31m✗ $1\033[0m"; }
header() { echo -e "\n\033[1;36m=== $1 ===\033[0m"; }
step() { echo -e "\n\033[1;33m$1\033[0m"; }

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

header "Running Pre-Provision Hooks"

# Key Vault Setup
step "[1/7] Setting up Key Vault..."
if ! "${SCRIPT_DIR}/ensure-keyvault.sh"; then
    error "Key Vault setup failed!"
    exit 1
fi
success "Key Vault setup completed"

# Resolve container images
step "[2/7] Resolving container images..."
if ! "${SCRIPT_DIR}/resolve-images.sh"; then
    error "Image resolution failed!"
    exit 1
fi
success "Image resolution completed"

# Validate ACR binding
step "[3/7] Validating ACR binding..."
if ! "${SCRIPT_DIR}/validate-acr-binding.sh"; then
    error "ACR validation failed!"
    exit 1
fi
success "ACR validation completed"

# Ensure ACR exists
step "[4/7] Ensuring ACR exists..."
if ! "${SCRIPT_DIR}/ensure-acr.sh"; then
    error "ACR setup failed!"
    exit 1
fi
success "ACR setup completed"

# Ensure DNS Zone exists (outside deployment stack)
step "[5/7] Ensuring DNS Zone exists..."
if ! "${SCRIPT_DIR}/ensure-dns-zone.sh"; then
    error "DNS Zone setup failed!"
    exit 1
fi
success "DNS Zone setup completed"

# Purge any soft-deleted App Config store (Standard SKU + VNet only)
step "[6/7] Checking for soft-deleted App Config stores..."
if ! "${SCRIPT_DIR}/recover-or-purge-appconfig.sh"; then
    error "App Config purge check failed!"
    exit 1
fi
success "App Config purge check completed"

# Remove stranded CAE that exists without VNet config (prevents ManagedEnvironmentCannotAddVnetToExistingEnv)
step "[7/8] Checking for stranded Container Apps Environment..."
if ! "${SCRIPT_DIR}/ensure-cae-vnet.sh"; then
    error "CAE VNet guard failed!"
    exit 1
fi
success "CAE VNet guard completed"

# Pre-provision backend managed identity and grant KV access before Bicep runs.
# Eliminates the KV access-policy propagation race condition that causes:
#   "unable to fetch secret using Managed identity"
# when the identity is freshly created in the same deployment as the Container App.
step "[8/9] Pre-provisioning backend identity for Key Vault access..."
if ! "${SCRIPT_DIR}/ensure-identities.sh"; then
    error "Identity pre-provisioning failed!"
    exit 1
fi
success "Identity pre-provisioning completed"

# Detect "azd down/up on retained-MI environment" and auto-set FORCE_SQL_SETUP_TAG.
# Prevents the sql-setup ACI from being a no-op when the DB was recreated but
# managed identity clientIds did not change (content-based detection limitation).
step "[9/9] Checking SQL setup state..."
if ! "${SCRIPT_DIR}/ensure-sql-setup.sh"; then
    error "SQL setup check failed!"
    exit 1
fi
success "SQL setup check completed"

header "Pre-Provision Hooks Completed Successfully"
exit 0
