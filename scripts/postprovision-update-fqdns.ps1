#!/usr/bin/env pwsh
# ==============================================================================
# Post-provision hook: Extract deployed FQDNs and update App Config entries
# ==============================================================================
# After the first provision, the frontend FQDN is known. This script:
#   1. Extracts frontendFqdn from azd outputs
#   2. Sets FRONTEND_URL and BACKEND_CORS_ALLOWED_ORIGINS in azd env
#   3. Re-provisions so App Config and ingress-level CORS get the correct values
# ==============================================================================

$ErrorActionPreference = "Stop"

Write-Host "`n━━━ Post-provision: Updating cross-service FQDNs ━━━" -ForegroundColor Cyan

# Extract FQDNs from azd environment (populated by Bicep outputs)
$frontendFqdn = azd env get-value frontendFqdn 2>$null
$backendFqdn  = azd env get-value backendFqdn  2>$null

if (-not $frontendFqdn -or $frontendFqdn -eq "null") {
    Write-Host "Warning: Could not retrieve frontend FQDN — skipping FQDN update" -ForegroundColor Yellow
    exit 0
}

Write-Host "Frontend FQDN : $frontendFqdn"
Write-Host "Backend  FQDN : $backendFqdn"

$frontendUrl = "https://$frontendFqdn"

# Check if values already match (skip re-provision if nothing changed)
$currentFrontendUrl = azd env get-value FRONTEND_URL 2>$null
$currentCors        = azd env get-value BACKEND_CORS_ALLOWED_ORIGINS 2>$null

if ($currentFrontendUrl -eq $frontendUrl -and $currentCors -eq $frontendUrl) {
    Write-Host "FRONTEND_URL and CORS already up-to-date — no re-provision needed" -ForegroundColor Green
    exit 0
}

# Set env vars for next provision
Write-Host "Setting FRONTEND_URL = $frontendUrl"
azd env set FRONTEND_URL $frontendUrl

Write-Host "Setting BACKEND_CORS_ALLOWED_ORIGINS = $frontendUrl"
azd env set BACKEND_CORS_ALLOWED_ORIGINS $frontendUrl

# Re-provision to push updated values into App Config and ingress CORS
Write-Host "`nRe-provisioning to update App Config and ingress CORS..." -ForegroundColor Cyan
azd provision --no-prompt

Write-Host "Cross-service FQDNs updated successfully" -ForegroundColor Green
