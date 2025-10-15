#!/usr/bin/env bash
set -euo pipefail

# Inputs (env)
# - SRC_IMAGE: full image (registry/path@sha256:...)
# - SRC_REPO: GitHub owner/repo for frontend source (do NOT confuse with ACR repo)
# - TARGET_ENV: target environment name (test|train|prod)
# - RG: Azure resource group of the Container App
# - SUB: Azure subscription id (optional; will auto-detect)
# - TGT_ACR: Target ACR name (without .azurecr.io) (optional)
# - PREV_IMAGE: previously deployed image (optional)
# - PREV_DIGEST: previously deployed digest (optional)
# - COMMITS_TABLE_LIMIT: max commits to render in the table (default 50)
# - FRONTEND_REPO_READ_TOKEN: optional PAT for cross-repo read
# - GITHUB_REPOSITORY/GITHUB_TOKEN/BUILD_URL are expected from workflow env

COMMITS_TABLE_LIMIT=${COMMITS_TABLE_LIMIT:-50}
SRC_IMAGE=${SRC_IMAGE:-}
SRC_REPO=${SRC_REPO:-}
TARGET_ENV=${TARGET_ENV:-}
RG=${RG:-}
SUB=${SUB:-}
TGT_ACR=${TGT_ACR:-}
PREV_IMAGE=${PREV_IMAGE:-}
PREV_DIGEST=${PREV_DIGEST:-}
BUILD_URL=${BUILD_URL:-}
FRONTEND_REPO_READ_TOKEN=${FRONTEND_REPO_READ_TOKEN:-}

if [[ -z "$SRC_IMAGE" || -z "$SRC_REPO" || -z "$TARGET_ENV" ]]; then
  echo "[relnotes] Missing required inputs (SRC_IMAGE, SRC_REPO, TARGET_ENV)" >&2
  exit 1
fi

if [[ -z "$SUB" ]]; then
  SUB=$(az account show --query id -o tsv 2>/dev/null || true)
fi

NEW_DIGEST="${SRC_IMAGE#*@}"
SRC_DOMAIN="${SRC_IMAGE%%/*}"
SRC_REG_NAME=$(echo "$SRC_DOMAIN" | sed 's/\.azurecr\.io$//')
SRC_PATH="${SRC_IMAGE#*/}"
# Important: do not overwrite GitHub repo; derive ACR repository separately
ACR_REPO="${SRC_PATH%@*}"

AZ_READY=0
if az account show -o none >/dev/null 2>&1; then AZ_READY=1; fi

# If previous digest wasn't provided and we have the previously deployed image, try to resolve
if [[ -z "$PREV_DIGEST" && -n "$PREV_IMAGE" ]]; then
  PREV_DOMAIN="${PREV_IMAGE%%/*}"
  PREV_REG=$(echo "$PREV_DOMAIN" | sed 's/\.azurecr\.io$//')
  PREV_PATH="${PREV_IMAGE#*/}"
  # PREV_REPO[:tag] or @digest
  if echo "$PREV_PATH" | grep -q '@'; then
    PREV_REPO="${PREV_PATH%@*}"
    PREV_TAG=""
  else
    PREV_REPO="${PREV_PATH%%:*}"
    if echo "$PREV_PATH" | grep -q ':'; then PREV_TAG="${PREV_PATH#*:}"; else PREV_TAG=""; fi
  fi
  if [[ -n "$TGT_ACR" && "$PREV_REG" == "$TGT_ACR" && -n "$PREV_TAG" && "$AZ_READY" -eq 1 ]]; then
    CANDIDATE=$(az acr repository show-manifests -n "$TGT_ACR" --subscription "$SUB" --repository "$PREV_REPO" --query "[?contains(join(',', tags), '$PREV_TAG')].digest | [0]" -o tsv 2>/dev/null || true)
    [[ -n "$CANDIDATE" ]] && PREV_DIGEST="$CANDIDATE"
  fi
fi

# Derive previous registry/repo from actual deployed image for accurate lookup
if [[ -n "$PREV_IMAGE" ]]; then
  PREV_DOMAIN="${PREV_IMAGE%%/*}"
  PREV_REG_NAME=$(echo "$PREV_DOMAIN" | sed 's/\.azurecr\.io$//')
  PREV_PATH="${PREV_IMAGE#*/}"
  PREV_REPO_NAME="${PREV_PATH%@*}"
fi

# If still not resolved and manual dispatch on target repo, pick latest digest
if [[ -z "$PREV_DIGEST" && -n "$TGT_ACR" && "$AZ_READY" -eq 1 ]]; then
  TGT_REPO="raptor/frontend-${TARGET_ENV}"
  LATEST=$(az acr repository show-manifests -n "$TGT_ACR" --subscription "$SUB" --repository "$TGT_REPO" --orderby time_desc --top 1 --query "[0].digest" -o tsv 2>/dev/null || true)
  [[ -n "$LATEST" ]] && PREV_DIGEST="$LATEST"
fi

# Robust OCI label extractor with proper data-plane OAuth and multi-arch support
get_commit_from_labels() {
  local reg="$1" repo="$2" dig="$3"
  if [[ -z "$dig" ]]; then echo ""; return 0; fi
  local refresh
  refresh=$(az acr login -n "$reg" --expose-token -o tsv --query accessToken 2>/dev/null || true)
  [[ -z "$refresh" ]] && { echo ""; return 0; }
  local base="https://${reg}.azurecr.io"
  local access
  access=$(curl -fsSL -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "service=${reg}.azurecr.io" \
    --data-urlencode "scope=repository:${repo}:pull" \
    --data-urlencode "refresh_token=${refresh}" \
    "$base/oauth2/token" 2>/dev/null | jq -r '.access_token // empty')
  [[ -z "$access" ]] && { echo ""; return 0; }
  local v2base="${base}/v2/${repo}"

  _fetch_manifest() {
    local digest="$1"
    curl -fsSL \
      -H "Authorization: Bearer $access" \
      -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
      "$v2base/manifests/$digest" 2>/dev/null || true
  }

  _extract_rev_from_manifest() {
    local manifest_json="$1"
    local cfg cfgJson rev
    cfg=$(printf '%s' "$manifest_json" | jq -r '.config.digest // empty')
    [[ -z "$cfg" ]] && { echo ""; return 0; }
    cfgJson=$(curl -fsSL -H "Authorization: Bearer $access" "$v2base/blobs/$cfg" 2>/dev/null || true)
    [[ -z "$cfgJson" ]] && { echo ""; return 0; }
    rev=$(printf '%s' "$cfgJson" | jq -r '
      .config.Labels["org.opencontainers.image.revision"]
      // .config.Labels["org.opencontainers.image.vcs-ref"]
      // .container_config.Labels["org.opencontainers.image.revision"]
      // .container_config.Labels["org.opencontainers.image.vcs-ref"]
      // empty')
    if [[ -z "$rev" ]]; then
      rev=$(printf '%s' "$cfgJson" | jq -r '
        (.config.Labels // {}) | to_entries | map(select((.key|ascii_downcase) == "org.opencontainers.image.revision")) | .[0].value // empty')
    fi
    printf '%s' "$rev"
  }

  local mf media
  mf=$(_fetch_manifest "$dig")
  [[ -z "$mf" ]] && { echo ""; return 0; }
  media=$(printf '%s' "$mf" | jq -r '.mediaType // empty')

  if [[ "$media" == "application/vnd.oci.image.index.v1+json" || "$media" == "application/vnd.docker.distribution.manifest.list.v2+json" ]]; then
    local child rev
    for child in $(printf '%s' "$mf" | jq -r '.manifests[].digest // empty'); do
      [[ -z "$child" ]] && continue
      rev=$(_extract_rev_from_manifest "$(_fetch_manifest "$child")")
      if [[ -n "$rev" ]]; then printf '%s' "$rev"; return 0; fi
    done
    echo ""; return 0
  fi
  _extract_rev_from_manifest "$mf"
}

# Debug helper
debug_rev() {
  local reg="$1" repo="$2" dig="$3" label="$4"
  echo "[debug] Inspecting $label: reg=$reg repo=$repo digest=${dig:0:25}..."
  if [[ -z "$reg" || -z "$repo" || -z "$dig" ]]; then echo "[debug] Skipping ($label): missing inputs"; return 0; fi
  local refresh access base v2base mf media cfgDig cfgJson rev1 rev2
  refresh=$(az acr login -n "$reg" --expose-token -o tsv --query accessToken 2>/dev/null || true)
  if [[ -z "$refresh" ]]; then echo "[debug] ($label) token MISSING for $reg"; return 0; fi
  base="https://${reg}.azurecr.io"
  access=$(curl -fsSL -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "service=${reg}.azurecr.io" \
    --data-urlencode "scope=repository:${repo}:pull" \
    --data-urlencode "refresh_token=${refresh}" \
    "$base/oauth2/token" 2>/dev/null | jq -r '.access_token // empty')
  if [[ -z "$access" ]]; then echo "[debug] ($label) access token exchange failed"; return 0; fi
  v2base="${base}/v2/${repo}"
  mf=$(curl -fsSL -H "Authorization: Bearer $access" -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' "$v2base/manifests/$dig" 2>/dev/null || true)
  if [[ -z "$mf" ]]; then echo "[debug] ($label) manifest fetch empty"; return 0; fi
  media=$(printf '%s' "$mf" | jq -r '.mediaType // empty')
  echo "[debug] ($label) mediaType=$media"
  if [[ "$media" == "application/vnd.oci.image.index.v1+json" || "$media" == "application/vnd.docker.distribution.manifest.list.v2+json" ]]; then
    local child count=0
    for child in $(printf '%s' "$mf" | jq -r '.manifests[].digest // empty'); do
      count=$((count+1)); [[ $count -gt 3 ]] && { echo "[debug] ($label) ...truncated child scan"; break; }
      echo "[debug] ($label) child[$count]=${child:0:25}..."
      local cmf; cmf=$(curl -fsSL -H "Authorization: Bearer $access" -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' "$v2base/manifests/$child" 2>/dev/null || true)
      [[ -z "$cmf" ]] && { echo "[debug] ($label) child manifest empty"; continue; }
      cfgDig=$(printf '%s' "$cmf" | jq -r '.config.digest // empty')
      echo "[debug] ($label) child cfg=${cfgDig:0:25}..."
      [[ -z "$cfgDig" ]] && continue
      cfgJson=$(curl -fsSL -H "Authorization: Bearer $access" "$v2base/blobs/$cfgDig" 2>/dev/null || true)
      [[ -z "$cfgJson" ]] && { echo "[debug] ($label) child cfg blob empty"; continue; }
      rev1=$(printf '%s' "$cfgJson" | jq -r '.config.Labels["org.opencontainers.image.revision"] // empty')
      rev2=$(printf '%s' "$cfgJson" | jq -r '.container_config.Labels["org.opencontainers.image.revision"] // empty')
      if [[ -n "$rev1" || -n "$rev2" ]]; then
        echo "[debug] ($label) revision found in child cfg: ${rev1:-$rev2}"
        break
      else
        echo "[debug] ($label) revision not present in child cfg labels"
      fi
    done
    return 0
  fi
  cfgDig=$(printf '%s' "$mf" | jq -r '.config.digest // empty')
  echo "[debug] ($label) cfg=${cfgDig:0:25}..."
  [[ -z "$cfgDig" ]] && return 0
  cfgJson=$(curl -fsSL -H "Authorization: Bearer $access" "$v2base/blobs/$cfgDig" 2>/dev/null || true)
  [[ -z "$cfgJson" ]] && { echo "[debug] ($label) cfg blob empty"; return 0; }
  local rev1 rev2
  rev1=$(printf '%s' "$cfgJson" | jq -r '.config.Labels["org.opencontainers.image.revision"] // empty')
  rev2=$(printf '%s' "$cfgJson" | jq -r '.container_config.Labels["org.opencontainers.image.revision"] // empty')
  if [[ -n "$rev1" || -n "$rev2" ]]; then
    echo "[debug] ($label) revision found in cfg: ${rev1:-$rev2}"
  else
    echo "[debug] ($label) revision not present in cfg labels"
  fi
}

NEW_COMMIT_SHORT=""; PREV_COMMIT_SHORT=""
NEW_SHA=""; PREV_SHA=""

if [[ -n "$NEW_DIGEST" ]]; then
  C=$(get_commit_from_labels "$SRC_REG_NAME" "$ACR_REPO" "$NEW_DIGEST"); [[ -n "$C" ]] && NEW_COMMIT_SHORT="${C:0:7}" && NEW_SHA="$C"
fi
if [[ -z "$PREV_COMMIT_SHORT" && -n "$PREV_DIGEST" ]]; then
  if [[ -n "${PREV_REG_NAME:-}" && -n "${PREV_REPO_NAME:-}" ]]; then C=$(get_commit_from_labels "$PREV_REG_NAME" "$PREV_REPO_NAME" "$PREV_DIGEST"); fi
  if [[ -z "${C:-}" && -n "$TGT_ACR" ]]; then TGT_REPO="raptor/frontend-${TARGET_ENV}"; C=$(get_commit_from_labels "$TGT_ACR" "$TGT_REPO" "$PREV_DIGEST"); fi
  if [[ -z "${C:-}" ]]; then C=$(get_commit_from_labels "$SRC_REG_NAME" "$ACR_REPO" "$PREV_DIGEST"); fi
  [[ -n "$C" ]] && PREV_COMMIT_SHORT="${C:0:7}" && PREV_SHA="$C"
fi

# Try to expand abbreviated SHAs to full SHAs via GitHub API
OWNER=$(echo "$SRC_REPO" | cut -d'/' -f1)
REPO_NAME=$(echo "$SRC_REPO" | cut -d'/' -f2)
GH_TOKEN_USE=""
if [[ "${GITHUB_REPOSITORY:-}" == "$SRC_REPO" ]]; then GH_TOKEN_USE="${GITHUB_TOKEN:-}"; else GH_TOKEN_USE="$FRONTEND_REPO_READ_TOKEN"; fi

resolve_full_sha() {
  local ref="$1"
  if [[ -z "$ref" || -z "$GH_TOKEN_USE" ]]; then echo "$ref"; return 0; fi
  local url="https://api.github.com/repos/${OWNER}/${REPO_NAME}/commits/${ref}"
  local tmp; tmp=$(mktemp)
  local code; code=$(curl -sS -H "Authorization: Bearer $GH_TOKEN_USE" -H "Accept: application/vnd.github+json" -o "$tmp" -w "%{http_code}" "$url" || true)
  if echo "$code" | grep -qE '^(200)$'; then
    jq -r '.sha // empty' < "$tmp"
  else
    echo "$ref"
  fi
}

if [[ -n "$NEW_SHA" && ${#NEW_SHA} -lt 40 ]]; then NEW_SHA=$(resolve_full_sha "$NEW_SHA"); fi
if [[ -z "$NEW_SHA" && -n "$NEW_COMMIT_SHORT" ]]; then NEW_SHA=$(resolve_full_sha "$NEW_COMMIT_SHORT"); fi
if [[ -n "$PREV_SHA" && ${#PREV_SHA} -lt 40 ]]; then PREV_SHA=$(resolve_full_sha "$PREV_SHA"); fi
if [[ -z "$PREV_SHA" && -n "$PREV_COMMIT_SHORT" ]]; then PREV_SHA=$(resolve_full_sha "$PREV_COMMIT_SHORT"); fi

# Normalize display shorts
[[ -n "$NEW_SHA" ]] && NEW_COMMIT_SHORT="${NEW_SHA:0:7}"
[[ -n "$PREV_SHA" ]] && PREV_COMMIT_SHORT="${PREV_SHA:0:7}"

REPO_URL="https://github.com/${SRC_REPO}"
NOTES_FILE="release-notes.md"
HTML_FILE="release-notes.html"

{
  echo "## Release notes: Promote frontend to ${TARGET_ENV}"
  echo
  echo "- Target environment: ${TARGET_ENV}"
  echo "- New image: ${SRC_IMAGE}"
  if [[ -n "$PREV_DIGEST" ]]; then
    echo "- Previously deployed digest: ${PREV_DIGEST}"
  else
    echo "- Previously deployed digest: (none - first promotion)"
  fi
  echo
  if [[ -n "${NEW_SHA:-$NEW_COMMIT_SHORT}" && -n "${PREV_SHA:-$PREV_COMMIT_SHORT}" ]]; then
    if [[ "${NEW_SHA:-$NEW_COMMIT_SHORT}" == "${PREV_SHA:-$PREV_COMMIT_SHORT}" ]]; then
      echo "### Changes"; echo; echo "No code changes detected (same commit: ${NEW_COMMIT_SHORT})."
    else
      echo "### Changes (${PREV_COMMIT_SHORT} → ${NEW_COMMIT_SHORT})"; echo
      echo "Compare: ${REPO_URL}/compare/${PREV_SHA:-$PREV_COMMIT_SHORT}...${NEW_SHA:-$NEW_COMMIT_SHORT}"
    fi
  else
    echo "Commit SHAs not available from image labels. Showing image digests only."
  fi
} > "$NOTES_FILE"

printf '<h2>Release notes: Promote frontend to %s</h2>\n<p><strong>Target environment:</strong> %s</p>\n<p><strong>New image:</strong> %s</p>\n' "$TARGET_ENV" "$TARGET_ENV" "$SRC_IMAGE" > "$HTML_FILE"
if [[ -n "$PREV_DIGEST" ]]; then echo "<p><strong>Previously deployed digest:</strong> ${PREV_DIGEST}</p>" >> "$HTML_FILE"; else echo "<p><strong>Previously deployed digest:</strong> (none - first promotion)</p>" >> "$HTML_FILE"; fi
if [[ -n "$BUILD_URL" ]]; then echo "<p><a href=\"${BUILD_URL}\">Build details</a></p>" >> "$HTML_FILE"; fi

if [[ -n "$PREV_DIGEST" ]]; then
  echo "<h3>Changes</h3>" >> "$HTML_FILE"
  printf '<p>Digest change: <code>%s</code> → <code>%s</code></p>\n' "$PREV_DIGEST" "$NEW_DIGEST" >> "$HTML_FILE"
  if [[ -n "${NEW_SHA:-$NEW_COMMIT_SHORT}" && -n "${PREV_SHA:-$PREV_COMMIT_SHORT}" ]]; then
    if [[ "${NEW_SHA:-$NEW_COMMIT_SHORT}" == "${PREV_SHA:-$PREV_COMMIT_SHORT}" ]]; then
      printf '<p>No code changes detected (same commit: <code>%s</code>).</p>\n' "$NEW_COMMIT_SHORT" >> "$HTML_FILE"
    else
      printf '<p>Compare commits: <a href="%s/compare/%s...%s">%s → %s</a></p>\n' "$REPO_URL" "${PREV_SHA:-$PREV_COMMIT_SHORT}" "${NEW_SHA:-$NEW_COMMIT_SHORT}" "${PREV_COMMIT_SHORT}" "${NEW_COMMIT_SHORT}" >> "$HTML_FILE"
      OWNER=$(echo "$SRC_REPO" | cut -d'/' -f1); REPO_NAME=$(echo "$SRC_REPO" | cut -d'/' -f2)
      API_URL="https://api.github.com/repos/${OWNER}/${REPO_NAME}/compare/${PREV_SHA:-$PREV_COMMIT_SHORT}...${NEW_SHA:-$NEW_COMMIT_SHORT}"
      GH_TOKEN_USE=""; if [[ "${GITHUB_REPOSITORY:-}" == "$SRC_REPO" ]]; then GH_TOKEN_USE="${GITHUB_TOKEN:-}"; else GH_TOKEN_USE="$FRONTEND_REPO_READ_TOKEN"; fi
      if [[ -n "$GH_TOKEN_USE" ]]; then
        echo "<details><summary>Commit log</summary>" >> "$HTML_FILE"
        echo '<table border="1" cellpadding="6" cellspacing="0"><thead><tr><th align="left">SHA</th><th align="left">Message</th><th align="left">Author</th><th align="left">Date</th></tr></thead><tbody>' >> "$HTML_FILE"
        TMP=$(mktemp)
        HTTP=$(curl -sS -H "Authorization: Bearer $GH_TOKEN_USE" -H "Accept: application/vnd.github+json" -o "$TMP" -w "%{http_code}" "$API_URL" || true)
        echo "response status = $HTTP, response = $TMP"
        if echo "$HTTP" | grep -qE '^(200|201|204)$'; then
          JSON=$(cat "$TMP"); MAX=${COMMITS_TABLE_LIMIT}
          TOTAL=$(printf '%s' "$JSON" | jq -r '(.commits // []) | length')
          printf '%s' "$JSON" | jq -r --argjson max "$MAX" '
            (.commits // []) | .[0:$max] | .[] | [
              .sha,
              (.html_url // ""),
              (.commit.message | split("\n")[0]),
              (.commit.author.name // .author.login // "n/a"),
              (.commit.author.date // .commit.committer.date // "n/a")
            ] | @tsv' |
          while IFS=$'\t' read -r SHA URL MSG AUTHOR DATE; do
            SHORT=${SHA:0:7}
            MSG_ESC=$(printf '%s' "$MSG" | sed 's/&/&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
            if [[ -n "$URL" ]]; then
              printf '<tr><td><a href="%s">%s</a></td><td>%s</td><td>%s</td><td><code>%s</code></td></tr>\n' "$URL" "$SHORT" "$MSG_ESC" "$AUTHOR" "$DATE" >> "$HTML_FILE"
            else
              printf '<tr><td><code>%s</code></td><td>%s</td><td>%s</td><td><code>%s</code></td></tr>\n' "$SHORT" "$MSG_ESC" "$AUTHOR" "$DATE" >> "$HTML_FILE"
            fi
          done
          echo "</tbody></table>" >> "$HTML_FILE"
          if [[ "$TOTAL" -gt "$MAX" ]]; then
            printf '<p>Showing first %d of %d commits. See the compare link above for the full list.</p>\n' "$MAX" "$TOTAL" >> "$HTML_FILE"
          fi
        else
          echo "[relnotes] Commit API failed ($HTTP) for: $API_URL" >&2
          echo '<p>(Commit details unavailable; see the compare link above.)</p>' >> "$HTML_FILE"
        fi
        echo "</details>" >> "$HTML_FILE"
      else
        echo "[relnotes] No token available to read ${SRC_REPO}. Skipping commit table." >&2
      fi
    fi
  else
    echo "<p>Commit SHAs not available from image labels.</p>" >> "$HTML_FILE"
  fi
fi

# Emit outputs
{
  echo 'body<<EOF'
  cat "$NOTES_FILE"
  echo 'EOF'
  echo 'html<<EOF'
  cat "$HTML_FILE"
  echo 'EOF'
} >> "$GITHUB_OUTPUT"

# Extra debug breadcrumbs
echo "\n[debug] ===== Label resolution debug ====="
debug_rev "$SRC_REG_NAME" "$ACR_REPO" "$NEW_DIGEST" "NEW"
if [[ -n "$PREV_DIGEST" ]]; then
  if [[ -n "${PREV_REG_NAME:-}" && -n "${PREV_REPO_NAME:-}" ]]; then
    debug_rev "$PREV_REG_NAME" "$PREV_REPO_NAME" "$PREV_DIGEST" "PREV(actual)"
  elif [[ -n "$TGT_ACR" ]]; then
    TGT_REPO="raptor/frontend-${TARGET_ENV}"
    debug_rev "$TGT_ACR" "$TGT_REPO" "$PREV_DIGEST" "PREV(target)"
  fi
fi
echo "[debug] ================================="