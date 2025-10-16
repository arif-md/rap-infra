#!/usr/bin/env bash
#
# get-commit-from-image.sh
# Extract git commit SHA from OCI image labels in Azure Container Registry
#
# Usage:
#   get-commit-from-image.sh <registry-name> <repository> <digest>
#
# Returns:
#   Git commit SHA from org.opencontainers.image.revision label, or empty string
#
# Example:
#   SHA=$(./get-commit-from-image.sh ngraptordev rap-fe sha256:abc123...)
#

set -euo pipefail

# Validate arguments
if [ $# -ne 3 ]; then
  echo "Usage: $0 <registry-name> <repository> <digest>" >&2
  exit 1
fi

REG_NAME="$1"
REPO="$2"
DIGEST="$3"

# Early return if no digest provided
if [ -z "$DIGEST" ]; then
  echo ""
  exit 0
fi

# Get ACR refresh token
REFRESH_TOKEN=""
REFRESH_TOKEN=$(az acr login -n "$REG_NAME" --expose-token -o tsv --query accessToken 2>/dev/null || true)
if [ -z "$REFRESH_TOKEN" ]; then
  echo "" >&2
  echo "Warning: Failed to get ACR refresh token for registry: $REG_NAME" >&2
  exit 0
fi

# Exchange refresh token for access token with repository scope
BASE_URL="https://${REG_NAME}.azurecr.io"
ACCESS_TOKEN=""
ACCESS_TOKEN=$(curl -fsSL \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "grant_type=refresh_token" \
  --data-urlencode "service=${REG_NAME}.azurecr.io" \
  --data-urlencode "scope=repository:${REPO}:pull" \
  --data-urlencode "refresh_token=${REFRESH_TOKEN}" \
  "$BASE_URL/oauth2/token" 2>/dev/null | jq -r '.access_token // empty')

if [ -z "$ACCESS_TOKEN" ]; then
  echo "" >&2
  echo "Warning: Failed to exchange refresh token for access token" >&2
  exit 0
fi

# Construct v2 API base URL
V2_BASE="$BASE_URL/v2/${REPO}"

# Fetch image manifest
MANIFEST=""
MANIFEST=$(curl -fsSL \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
  "$V2_BASE/manifests/$DIGEST" 2>/dev/null || true)

if [ -z "$MANIFEST" ]; then
  echo "" >&2
  echo "Warning: Failed to fetch manifest for digest: $DIGEST" >&2
  exit 0
fi

# Check if manifest is a multi-platform index/list
MEDIA_TYPE=$(echo "$MANIFEST" | jq -r '.mediaType // empty')
if [ "$MEDIA_TYPE" = "application/vnd.oci.image.index.v1+json" ] || [ "$MEDIA_TYPE" = "application/vnd.docker.distribution.manifest.list.v2+json" ]; then
  # Get first platform-specific manifest
  CHILD_DIGEST=$(echo "$MANIFEST" | jq -r '.manifests[0].digest // empty')
  if [ -n "$CHILD_DIGEST" ]; then
    MANIFEST=$(curl -fsSL \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
      "$V2_BASE/manifests/$CHILD_DIGEST" 2>/dev/null || true)
  fi
fi

# Extract config digest from manifest
CONFIG_DIGEST=$(echo "$MANIFEST" | jq -r '.config.digest // empty')
if [ -z "$CONFIG_DIGEST" ]; then
  echo "" >&2
  echo "Warning: No config digest found in manifest" >&2
  exit 0
fi

# Fetch image config blob
CONFIG_JSON=""
CONFIG_JSON=$(curl -fsSL \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$V2_BASE/blobs/$CONFIG_DIGEST" 2>/dev/null || true)

if [ -z "$CONFIG_JSON" ]; then
  echo "" >&2
  echo "Warning: Failed to fetch config blob for digest: $CONFIG_DIGEST" >&2
  exit 0
fi

# Extract commit SHA from OCI label
COMMIT_SHA=$(echo "$CONFIG_JSON" | jq -r '.config.Labels["org.opencontainers.image.revision"] // empty')

# Output commit SHA (or empty string)
echo "$COMMIT_SHA"
