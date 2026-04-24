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
step "[1/5] Setting up Key Vault..."
if ! "${SCRIPT_DIR}/ensure-keyvault.sh"; then
    error "Key Vault setup failed!"
    exit 1
fi
success "Key Vault setup completed"

# Resolve container images
step "[2/5] Resolving container images..."
if ! "${SCRIPT_DIR}/resolve-images.sh"; then
    error "Image resolution failed!"
    exit 1
fi
success "Image resolution completed"

# Validate ACR binding
step "[3/5] Validating ACR binding..."
if ! "${SCRIPT_DIR}/validate-acr-binding.sh"; then
    error "ACR validation failed!"
    exit 1
fi
success "ACR validation completed"

# Ensure ACR exists
step "[4/5] Ensuring ACR exists..."
if ! "${SCRIPT_DIR}/ensure-acr.sh"; then
    error "ACR setup failed!"
    exit 1
fi
success "ACR setup completed"

# Ensure DNS Zone exists (outside deployment stack)
step "[5/6] Ensuring DNS Zone exists..."
if ! "${SCRIPT_DIR}/ensure-dns-zone.sh"; then
    error "DNS Zone setup failed!"
    exit 1
fi
success "DNS Zone setup completed"

# Purge any soft-deleted App Config store (Standard SKU + VNet only)
step "[6/6] Checking for soft-deleted App Config stores..."
if ! "${SCRIPT_DIR}/recover-or-purge-appconfig.sh"; then
    error "App Config purge check failed!"
    exit 1
fi
success "App Config purge check completed"

header "Pre-Provision Hooks Completed Successfully"
exit 0
