#!/usr/bin/env bash
# Validation script: Check consistency between image sources and per-service SKIP_ACR_PULL_ROLE_ASSIGNMENT flags
# This script is called from both local azd up and GitHub Actions workflows

set -euo pipefail

echo "🔍 Validating per-service image vs ACR binding consistency..."

# Get environment variables
AZURE_ACR_NAME=$(azd env get-value AZURE_ACR_NAME 2>/dev/null || echo "")
FRONTEND_IMG=$(azd env get-value SERVICE_FRONTEND_IMAGE_NAME 2>/dev/null || echo "")
BACKEND_IMG=$(azd env get-value SERVICE_BACKEND_IMAGE_NAME 2>/dev/null || echo "")
SKIP_FRONTEND=$(azd env get-value SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT 2>/dev/null || echo "true")
SKIP_BACKEND=$(azd env get-value SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT 2>/dev/null || echo "true")

if [ -z "$AZURE_ACR_NAME" ]; then
  echo "⚠️  AZURE_ACR_NAME not set. Skipping validation."
  exit 0
fi

ACR_DOMAIN="${AZURE_ACR_NAME}.azurecr.io"
HAS_ERROR=false

# Validate frontend
echo ""
echo "📦 Validating frontend..."
if [[ "$FRONTEND_IMG" == *"$ACR_DOMAIN"* ]]; then
  echo "   Image: $FRONTEND_IMG (ACR)"
  if [ "$SKIP_FRONTEND" = "true" ]; then
    echo "   ❌ ERROR: Frontend uses ACR but SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=true"
    echo "      This will cause deployment failure - Container App won't be able to pull image."
    HAS_ERROR=true
  else
    echo "   ✅ SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=false (correct)"
  fi
else
  echo "   Image: $FRONTEND_IMG (public/external)"
  if [ "$SKIP_FRONTEND" = "false" ]; then
    echo "   ⚠️  WARNING: Frontend uses public image but SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=false"
    echo "      This won't cause errors, but creates unnecessary role assignment."
  else
    echo "   ✅ SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=true (correct)"
  fi
fi

# Validate backend
echo ""
echo "📦 Validating backend..."
if [[ "$BACKEND_IMG" == *"$ACR_DOMAIN"* ]]; then
  echo "   Image: $BACKEND_IMG (ACR)"
  if [ "$SKIP_BACKEND" = "true" ]; then
    echo "   ❌ ERROR: Backend uses ACR but SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=true"
    echo "      This will cause deployment failure - Container App won't be able to pull image."
    HAS_ERROR=true
  else
    echo "   ✅ SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=false (correct)"
  fi
else
  echo "   Image: $BACKEND_IMG (public/external)"
  if [ "$SKIP_BACKEND" = "false" ]; then
    echo "   ⚠️  WARNING: Backend uses public image but SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=false"
    echo "      This won't cause errors, but creates unnecessary role assignment."
  else
    echo "   ✅ SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=true (correct)"
  fi
fi

if [ "$HAS_ERROR" = "true" ]; then
  echo ""
  echo "❌ Validation failed! Fix: Run './scripts/resolve-images.sh' to recalculate SKIP flags."
  exit 1
fi

echo ""
echo "✅ Per-service image vs ACR binding validation passed."
