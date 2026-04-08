#!/usr/bin/env bash
# ==============================================================================
# Post-provision hook: Extract deployed FQDNs and update App Config entries
# ==============================================================================
set -euo pipefail

echo ""
echo "━━━ Post-provision: Updating cross-service FQDNs ━━━"

# Extract FQDNs from azd environment (populated by Bicep outputs)
FRONTEND_FQDN=$(azd env get-value frontendFqdn 2>/dev/null || echo "")
BACKEND_FQDN=$(azd env get-value backendFqdn 2>/dev/null || echo "")

if [ -z "$FRONTEND_FQDN" ] || [ "$FRONTEND_FQDN" = "null" ]; then
    echo "Warning: Could not retrieve frontend FQDN — skipping FQDN update"
    exit 0
fi

echo "Frontend FQDN : $FRONTEND_FQDN"
echo "Backend  FQDN : $BACKEND_FQDN"

FRONTEND_URL="https://$FRONTEND_FQDN"

# Check if values already match (skip re-provision if nothing changed)
CURRENT_FRONTEND_URL=$(azd env get-value FRONTEND_URL 2>/dev/null || echo "")
CURRENT_CORS=$(azd env get-value BACKEND_CORS_ALLOWED_ORIGINS 2>/dev/null || echo "")

if [ "$CURRENT_FRONTEND_URL" = "$FRONTEND_URL" ] && [ "$CURRENT_CORS" = "$FRONTEND_URL" ]; then
    echo "FRONTEND_URL and CORS already up-to-date — no re-provision needed"
    exit 0
fi

# Set env vars for next provision
echo "Setting FRONTEND_URL = $FRONTEND_URL"
azd env set FRONTEND_URL "$FRONTEND_URL"

echo "Setting BACKEND_CORS_ALLOWED_ORIGINS = $FRONTEND_URL"
azd env set BACKEND_CORS_ALLOWED_ORIGINS "$FRONTEND_URL"

# Re-provision to push updated values into App Config and ingress CORS
echo ""
echo "Re-provisioning to update App Config and ingress CORS..."
azd provision --no-prompt

echo "Cross-service FQDNs updated successfully"
