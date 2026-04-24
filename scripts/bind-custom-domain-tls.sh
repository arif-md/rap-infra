#!/bin/bash

###############################################################################
# Post-Provision: Add Custom Domain + TLS Certificate to Route Config
###############################################################################
# Bicep deploys httpRouteConfig with routing rules ONLY (no customDomains).
# ALL DNS and custom domain lifecycle is handled here:
#   1. Checks if TLS is already properly bound (skip if yes)
#   2. Creates/updates DNS A + TXT records in Azure DNS zone (if managed)
#   3. Waits for DNS TXT propagation
#   4. Adds the custom domain to the route config (bindingType=Disabled)
#   5. Creates or reuses a managed TLS certificate (HTTP validation)
#   6. Binds the certificate to the route config (SniEnabled)
#
# Why not in Bicep?
#   - customDomains on httpRouteConfig triggers ARM domain validation that
#     queries public DNS. After azd down/up, DNS may not have propagated.
#   - DNS records in Bicep are managed by the deployment stack and get deleted
#     on azd down, causing propagation issues on the next azd up.
#   - Doing it here lets us create records, wait for propagation, and retry.
###############################################################################

set -e

# Lock down App Config + Key Vault public network access when VNet is enabled.
# Runs before the custom-domain early-exit so it executes even when no custom domain is configured.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"
if [ -f "$SCRIPT_DIR/lock-network-access.sh" ]; then
  bash "$SCRIPT_DIR/lock-network-access.sh"
else
  echo "lock-network-access.sh not found — skipping."
fi

CUSTOM_DOMAIN=$(azd env get-value CUSTOM_DOMAIN_NAME 2>/dev/null || true)
if [ -z "$CUSTOM_DOMAIN" ]; then
    echo "CUSTOM_DOMAIN_NAME not set. Skipping custom domain setup."
    exit 0
fi

RG=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || true)
if [ -z "$RG" ]; then
    echo "Missing AZURE_RESOURCE_GROUP. Skipping."
    exit 0
fi

# Discover the CAE name from the resource group
CAE_NAME=$(az containerapp env list -g "$RG" --query "[0].name" -o tsv 2>/dev/null || true)
if [ -z "$CAE_NAME" ]; then
    echo "No Container Apps Environment found in $RG. Skipping."
    exit 0
fi

# Detect if CAE is internal (VNet-only, no public IP) → must use TXT cert validation
CAE_INTERNAL=$(az containerapp env show -g "$RG" -n "$CAE_NAME" \
    --query "properties.vnetConfiguration.internal" -o tsv 2>/dev/null || true)
if [ "$CAE_INTERNAL" = "true" ]; then
    CERT_VALIDATION_METHOD="TXT"
else
    CERT_VALIDATION_METHOD="HTTP"
fi
echo "  CAE internal=$CAE_INTERNAL → cert validation: $CERT_VALIDATION_METHOD"

# Check route config exists
ROUTE_EXISTS=$(az containerapp env http-route-config show -g "$RG" -n "$CAE_NAME" -r raptorrouting --query "name" -o tsv 2>/dev/null || true)
if [ -z "$ROUTE_EXISTS" ]; then
    echo "Route config 'raptorrouting' not found. Skipping."
    exit 0
fi

SECONDS=0
echo "==> Setting up custom domain: $CUSTOM_DOMAIN ..."

# ── Helper: Build YAML from current route config with specified domain settings ──
build_route_yaml() {
    local domain="$1"
    local binding_type="$2"
    local cert_id="${3:-}"

    local route_json
    route_json=$(az containerapp env http-route-config show -g "$RG" -n "$CAE_NAME" -r raptorrouting -o json 2>/dev/null)

    local yaml=""
    yaml+="customDomains:\n"
    yaml+="  - name: $domain\n"
    yaml+="    bindingType: $binding_type\n"
    if [ -n "$cert_id" ]; then
        yaml+="    certificateId: $cert_id\n"
    fi
    yaml+="rules:\n"

    # Parse rules using jq
    local rules_count
    rules_count=$(echo "$route_json" | jq '.properties.rules | length')

    for ((i=0; i<rules_count; i++)); do
        local desc
        desc=$(echo "$route_json" | jq -r ".properties.rules[$i].description")
        yaml+="  - description: \"$desc\"\n"
        yaml+="    routes:\n"

        local routes_count
        routes_count=$(echo "$route_json" | jq ".properties.rules[$i].routes | length")
        for ((j=0; j<routes_count; j++)); do
            local psp prefix pr
            psp=$(echo "$route_json" | jq -r ".properties.rules[$i].routes[$j].match.pathSeparatedPrefix // empty")
            prefix=$(echo "$route_json" | jq -r ".properties.rules[$i].routes[$j].match.prefix // empty")
            pr=$(echo "$route_json" | jq -r ".properties.rules[$i].routes[$j].action.prefixRewrite // empty")

            if [ -n "$psp" ]; then
                yaml+="      - match:\n"
                yaml+="          pathSeparatedPrefix: $psp\n"
            elif [ -n "$prefix" ]; then
                yaml+="      - match:\n"
                yaml+="          prefix: $prefix\n"
            fi
            if [ -n "$pr" ]; then
                yaml+="        action:\n"
                yaml+="          prefixRewrite: $pr\n"
            fi
        done

        yaml+="    targets:\n"
        local targets_count
        targets_count=$(echo "$route_json" | jq ".properties.rules[$i].targets | length")
        for ((k=0; k<targets_count; k++)); do
            local ca
            ca=$(echo "$route_json" | jq -r ".properties.rules[$i].targets[$k].containerApp")
            yaml+="      - containerApp: $ca\n"
        done
    done

    echo -e "$yaml"
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: Check if TLS is already properly bound
# ══════════════════════════════════════════════════════════════════════════════
CURRENT_BINDING=$(az containerapp env http-route-config show \
    -g "$RG" -n "$CAE_NAME" -r raptorrouting \
    --query "properties.customDomains[?name=='$CUSTOM_DOMAIN'].bindingType | [0]" -o tsv 2>/dev/null || true)
CURRENT_CERT_ID=$(az containerapp env http-route-config show \
    -g "$RG" -n "$CAE_NAME" -r raptorrouting \
    --query "properties.customDomains[?name=='$CUSTOM_DOMAIN'].certificateId | [0]" -o tsv 2>/dev/null || true)

if [ "$CURRENT_BINDING" = "SniEnabled" ] && [ -n "$CURRENT_CERT_ID" ]; then
    CERT_EXISTS=$(az containerapp env certificate list \
        -g "$RG" -n "$CAE_NAME" \
        --query "[?id=='$CURRENT_CERT_ID' && properties.provisioningState=='Succeeded'].id" -o tsv 2>/dev/null || true)

    if [ -n "$CERT_EXISTS" ]; then
        echo "==> TLS already bound with valid certificate. Nothing to do. (${SECONDS}s)"
        exit 0
    fi
    echo "  Route binding references missing/invalid certificate. Re-binding..."
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Create/update DNS records in Azure DNS zone (if managed)
# ══════════════════════════════════════════════════════════════════════════════
VERIFICATION_ID=$(az containerapp env show -g "$RG" -n "$CAE_NAME" \
    --query "properties.customDomainConfiguration.customDomainVerificationId" -o tsv 2>/dev/null || true)

ENABLE_AZURE_DNS=$(azd env get-value ENABLE_AZURE_DNS 2>/dev/null || true)
if [ "$ENABLE_AZURE_DNS" = "true" ]; then
    STATIC_IP=$(az containerapp env show -g "$RG" -n "$CAE_NAME" \
        --query "properties.staticIp" -o tsv 2>/dev/null || true)

    if [ -z "$STATIC_IP" ] || [ -z "$VERIFICATION_ID" ]; then
        echo "ERROR: Could not retrieve CAE static IP or verification ID."
        exit 1
    fi

    echo "  Creating/updating DNS records in Azure DNS zone..."

    # A record: customDomain → CAE static IP
    # Delete entire record set and recreate to avoid stale IPs accumulating
    # (add-record appends; after azd down/up the CAE IP changes)
    EXISTING_A_RECORDS=$(az network dns record-set a show -g "$RG" -z "$CUSTOM_DOMAIN" -n "@" --query "ARecords[].ipv4Address" -o tsv 2>/dev/null || true)
    A_RECORD_COUNT=$(echo "$EXISTING_A_RECORDS" | grep -c . 2>/dev/null || echo 0)
    A_RECORD_CORRECT=false
    if [ "$A_RECORD_COUNT" -eq 1 ] && [ "$(echo "$EXISTING_A_RECORDS" | tr -d '\r\n')" = "$STATIC_IP" ]; then
        A_RECORD_CORRECT=true
    fi

    if [ "$A_RECORD_CORRECT" = "false" ]; then
        if [ "$A_RECORD_COUNT" -gt 0 ] && [ -n "$EXISTING_A_RECORDS" ]; then
            az network dns record-set a delete -g "$RG" -z "$CUSTOM_DOMAIN" -n "@" --yes --only-show-errors 2>/dev/null || true
        fi
        az network dns record-set a add-record -g "$RG" -z "$CUSTOM_DOMAIN" -n "@" -a "$STATIC_IP" --only-show-errors 2>/dev/null
        echo "    A record: $CUSTOM_DOMAIN → $STATIC_IP"
    else
        echo "    A record already correct: $CUSTOM_DOMAIN → $STATIC_IP"
    fi

    # TXT record: asuid.customDomain → verification ID
    # Same approach: delete entire record set and recreate to avoid stale values
    EXISTING_TXT_RECORDS=$(az network dns record-set txt show -g "$RG" -z "$CUSTOM_DOMAIN" -n "asuid" --query "TXTRecords[].value[0]" -o tsv 2>/dev/null || true)
    TXT_RECORD_COUNT=$(echo "$EXISTING_TXT_RECORDS" | grep -c . 2>/dev/null || echo 0)
    TXT_RECORD_CORRECT=false
    if [ "$TXT_RECORD_COUNT" -eq 1 ] && [ "$(echo "$EXISTING_TXT_RECORDS" | tr -d '\r\n')" = "$VERIFICATION_ID" ]; then
        TXT_RECORD_CORRECT=true
    fi

    if [ "$TXT_RECORD_CORRECT" = "false" ]; then
        if [ "$TXT_RECORD_COUNT" -gt 0 ] && [ -n "$EXISTING_TXT_RECORDS" ]; then
            az network dns record-set txt delete -g "$RG" -z "$CUSTOM_DOMAIN" -n "asuid" --yes --only-show-errors 2>/dev/null || true
        fi
        az network dns record-set txt add-record -g "$RG" -z "$CUSTOM_DOMAIN" -n "asuid" -v "$VERIFICATION_ID" --only-show-errors 2>/dev/null
        echo "    TXT record: asuid.$CUSTOM_DOMAIN → ${VERIFICATION_ID:0:16}..."
    else
        echo "    TXT record already correct."
    fi

    echo "  DNS records ready. (${SECONDS}s)"
else
    echo "  Azure DNS not managed (ENABLE_AZURE_DNS != true). Expecting manual DNS."
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: Ensure DNS TXT record is resolvable (wait for propagation)
# ══════════════════════════════════════════════════════════════════════════════
echo "  Checking DNS TXT record for asuid.$CUSTOM_DOMAIN ..."
DNS_READY=false
DNS_ATTEMPTS=0
MAX_DNS_ATTEMPTS=24  # 2 minutes max (24 * 5s)

while [ "$DNS_READY" = "false" ] && [ "$DNS_ATTEMPTS" -lt "$MAX_DNS_ATTEMPTS" ]; do
    TXT_RESULT=$(dig +short TXT "asuid.$CUSTOM_DOMAIN" 2>/dev/null || true)
    if echo "$TXT_RESULT" | grep -q "$VERIFICATION_ID"; then
        DNS_READY=true
    else
        DNS_ATTEMPTS=$((DNS_ATTEMPTS + 1))
        if [ "$DNS_ATTEMPTS" -eq 1 ]; then
            echo "  Waiting for DNS propagation..."
        fi
        if [ $((DNS_ATTEMPTS % 6)) -eq 0 ]; then
            echo "  Still waiting... (${SECONDS}s)"
        fi
        sleep 5
    fi
done

if [ "$DNS_READY" = "false" ]; then
    echo "WARNING: DNS TXT record not resolvable after 2 minutes."
    echo "  Expected: asuid.$CUSTOM_DOMAIN TXT $VERIFICATION_ID"
    echo "  Custom domain setup will be skipped. Re-run after DNS propagates:"
    echo "  ./scripts/bind-custom-domain-tls.sh"
    exit 0
fi
echo "  DNS TXT record verified. (${SECONDS}s)"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Add custom domain to route config (if not already present)
# ══════════════════════════════════════════════════════════════════════════════
DOMAIN_ON_ROUTE=$(az containerapp env http-route-config show \
    -g "$RG" -n "$CAE_NAME" -r raptorrouting \
    --query "properties.customDomains[?name=='$CUSTOM_DOMAIN'].name | [0]" -o tsv 2>/dev/null || true)

if [ -z "$DOMAIN_ON_ROUTE" ]; then
    echo "  Adding custom domain to route config (Disabled)..."
    YAML_PATH=$(mktemp /tmp/route-config-domain-XXXXXX.yaml)
    build_route_yaml "$CUSTOM_DOMAIN" "Disabled" > "$YAML_PATH"
    az containerapp env http-route-config update \
        -g "$RG" -n "$CAE_NAME" -r raptorrouting \
        --yaml "$YAML_PATH" --only-show-errors 2>/dev/null
    rm -f "$YAML_PATH"
    echo "  Custom domain added. (${SECONDS}s)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: Create or reuse TLS certificate
# ══════════════════════════════════════════════════════════════════════════════
EXISTING_CERT=$(az containerapp env certificate list \
    -g "$RG" -n "$CAE_NAME" \
    --query "[?properties.subjectName=='$CUSTOM_DOMAIN' && properties.provisioningState=='Succeeded'].id | [0]" -o tsv 2>/dev/null || true)

if [ -z "$EXISTING_CERT" ]; then
    # Clean up stuck/failed/pending certificates
    BAD_CERTS=$(az containerapp env certificate list \
        -g "$RG" -n "$CAE_NAME" \
        --query "[?properties.subjectName=='$CUSTOM_DOMAIN' && properties.provisioningState!='Succeeded'].id" -o tsv 2>/dev/null || true)

    if [ -n "$BAD_CERTS" ]; then
        echo "$BAD_CERTS" | while IFS= read -r cert_id; do
            cert_id=$(echo "$cert_id" | tr -d '\r')
            if [ -n "$cert_id" ]; then
                echo "  Removing stale certificate: $(basename "$cert_id")"
                az containerapp env certificate delete -g "$RG" -n "$CAE_NAME" --certificate "$cert_id" --yes 2>/dev/null || true
            fi
        done
    fi

    echo "  Creating managed certificate ($CERT_VALIDATION_METHOD validation)..."
    CERT_OUTPUT=$(az containerapp env certificate create \
        -g "$RG" -n "$CAE_NAME" \
        --hostname "$CUSTOM_DOMAIN" \
        --validation-method "$CERT_VALIDATION_METHOD" \
        --only-show-errors 2>/dev/null)

    # For TXT validation: create the _dnsauth DNS record with the validation token
    if [ "$CERT_VALIDATION_METHOD" = "TXT" ] && [ "$ENABLE_AZURE_DNS" = "true" ]; then
        VALIDATION_TOKEN=$(echo "$CERT_OUTPUT" | jq -r '.properties.validationToken // empty')
        if [ -n "$VALIDATION_TOKEN" ]; then
            echo "  Creating _dnsauth TXT record for cert validation..."
            az network dns record-set txt delete -g "$RG" -z "$CUSTOM_DOMAIN" -n "_dnsauth" --yes --only-show-errors 2>/dev/null || true
            az network dns record-set txt add-record -g "$RG" -z "$CUSTOM_DOMAIN" -n "_dnsauth" -v "$VALIDATION_TOKEN" --only-show-errors 2>/dev/null
            echo "    TXT record: _dnsauth.$CUSTOM_DOMAIN → $VALIDATION_TOKEN"
        else
            echo "  WARNING: Could not extract validationToken from cert output."
        fi
    fi

    # Poll for provisioning (5s interval, max 5 minutes)
    MAX_CERT_ATTEMPTS=60
    CERT_ATTEMPT=0
    CERT_STATE="Pending"

    while [ "$CERT_STATE" != "Succeeded" ] && [ "$CERT_ATTEMPT" -lt "$MAX_CERT_ATTEMPTS" ]; do
        CERT_ATTEMPT=$((CERT_ATTEMPT + 1))
        sleep 5
        CERT_STATE=$(az containerapp env certificate list \
            -g "$RG" -n "$CAE_NAME" \
            --query "[?properties.subjectName=='$CUSTOM_DOMAIN'].properties.provisioningState | [0]" -o tsv 2>/dev/null || true)

        if [ $((CERT_ATTEMPT % 6)) -eq 0 ]; then
            echo "  Certificate: $CERT_STATE (${SECONDS}s elapsed)"
        fi

        if [ "$CERT_STATE" = "Failed" ]; then
            echo "ERROR: Certificate provisioning failed."
            echo "  Check: az containerapp env certificate list -g $RG -n $CAE_NAME -o table"
            exit 1
        fi
    done

    if [ "$CERT_STATE" != "Succeeded" ]; then
        echo "WARNING: Certificate did not provision within 5 minutes."
        echo "  Re-run: ./scripts/bind-custom-domain-tls.sh"
        exit 0
    fi

    EXISTING_CERT=$(az containerapp env certificate list \
        -g "$RG" -n "$CAE_NAME" \
        --query "[?properties.subjectName=='$CUSTOM_DOMAIN' && properties.provisioningState=='Succeeded'].id | [0]" -o tsv 2>/dev/null || true)
fi

echo "  Certificate ready: $(basename "$EXISTING_CERT") (${SECONDS}s)"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6: Bind TLS certificate (SniEnabled)
# ══════════════════════════════════════════════════════════════════════════════
echo "  Updating route config to SniEnabled..."
YAML_PATH=$(mktemp /tmp/route-config-tls-XXXXXX.yaml)
build_route_yaml "$CUSTOM_DOMAIN" "SniEnabled" "$EXISTING_CERT" > "$YAML_PATH"
az containerapp env http-route-config update \
    -g "$RG" -n "$CAE_NAME" -r raptorrouting \
    --yaml "$YAML_PATH" --only-show-errors 2>/dev/null
rm -f "$YAML_PATH"

# ── Verify binding ──
FINAL_BINDING=$(az containerapp env http-route-config show \
    -g "$RG" -n "$CAE_NAME" -r raptorrouting \
    --query "properties.customDomains[?name=='$CUSTOM_DOMAIN'].bindingType | [0]" -o tsv 2>/dev/null || true)

if [ "$FINAL_BINDING" = "SniEnabled" ]; then
    echo "==> TLS bound! https://$CUSTOM_DOMAIN is ready. (total: ${SECONDS}s)"
else
    echo "WARNING: Binding state: $FINAL_BINDING (expected SniEnabled)"
    echo "  Check: az containerapp env http-route-config show -g $RG -n $CAE_NAME -r raptorrouting"
fi
