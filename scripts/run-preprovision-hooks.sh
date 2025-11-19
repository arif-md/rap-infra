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
step "[1/4] Setting up Key Vault..."
if ! "${SCRIPT_DIR}/ensure-keyvault.sh"; then
    error "Key Vault setup failed!"
    exit 1
fi
success "Key Vault setup completed"

# Resolve container images
step "[2/4] Resolving container images..."
if ! "${SCRIPT_DIR}/resolve-images.sh"; then
    error "Image resolution failed!"
    exit 1
fi
success "Image resolution completed"

# Validate ACR binding
step "[3/4] Validating ACR binding..."
if ! "${SCRIPT_DIR}/validate-acr-binding.sh"; then
    error "ACR validation failed!"
    exit 1
fi
success "ACR validation completed"

# Ensure ACR exists
step "[4/4] Ensuring ACR exists..."
if ! "${SCRIPT_DIR}/ensure-acr.sh"; then
    error "ACR setup failed!"
    exit 1
fi
success "ACR setup completed"

header "Pre-Provision Hooks Completed Successfully"
exit 0
