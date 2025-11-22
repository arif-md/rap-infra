# OIDC Custom Parameters - Complete Flow

This document traces the complete flow of OIDC custom authorization parameters from GitHub variables through deployment to runtime.

## Overview

The system supports adding custom OIDC authorization request parameters (like `acr_values`, `prompt`, `response_type`) without code changes. This is done through environment variables that flow through multiple layers.

## Configuration Flow

### 1. GitHub Repository Variables

**Location**: GitHub → Settings → Secrets and variables → Actions → Variables

Set individual variables for each parameter:
- `OIDC_ADDL_REQ_PARAM_ACR_VALUES` = `http://idmanagement.gov/ns/assurance/ial/1`
- `OIDC_ADDL_REQ_PARAM_PROMPT` = `login`
- `OIDC_ADDL_REQ_PARAM_RESPONSE_TYPE` = `code`

### 2. GitHub Actions Workflow

**File**: `infra/.github/workflows/provision-infrastructure.yaml`

**Lines 197-209**: The workflow reads GitHub variables and sets them in the azd environment:

```yaml
# Set individual OIDC additional parameters (simpler than JSON parsing)
if [ -n "${{ vars.OIDC_ADDL_REQ_PARAM_ACR_VALUES || '' }}" ]; then
  azd env set OIDC_ADDL_REQ_PARAM_ACR_VALUES "${{ vars.OIDC_ADDL_REQ_PARAM_ACR_VALUES }}"
  echo "✓ OIDC_ADDL_REQ_PARAM_ACR_VALUES configured"
fi

if [ -n "${{ vars.OIDC_ADDL_REQ_PARAM_PROMPT || '' }}" ]; then
  azd env set OIDC_ADDL_REQ_PARAM_PROMPT "${{ vars.OIDC_ADDL_REQ_PARAM_PROMPT }}"
  echo "✓ OIDC_ADDL_REQ_PARAM_PROMPT configured"
fi

if [ -n "${{ vars.OIDC_ADDL_REQ_PARAM_RESPONSE_TYPE || '' }}" ]; then
  azd env set OIDC_ADDL_REQ_PARAM_RESPONSE_TYPE "${{ vars.OIDC_ADDL_REQ_PARAM_RESPONSE_TYPE }}"
  echo "✓ OIDC_ADDL_REQ_PARAM_RESPONSE_TYPE configured"
fi
```

**Result**: Variables stored in `infra/.azure/{env}/.env` file:
```
OIDC_ADDL_REQ_PARAM_ACR_VALUES="http://idmanagement.gov/ns/assurance/ial/1"
OIDC_ADDL_REQ_PARAM_PROMPT="login"
OIDC_ADDL_REQ_PARAM_RESPONSE_TYPE="code"
```

### 3. Bicep Parameters File

**File**: `infra/main.parameters.json`

**Lines 107-115**: Maps azd environment variables to Bicep parameters:

```json
"oidcAcrValues": {
  "value": "${OIDC_ADDL_REQ_PARAM_ACR_VALUES=}"
},
"oidcPrompt": {
  "value": "${OIDC_ADDL_REQ_PARAM_PROMPT=}"
},
"oidcResponseType": {
  "value": "${OIDC_ADDL_REQ_PARAM_RESPONSE_TYPE=}"
}
```

**azd behavior**: Reads `.azure/{env}/.env`, substitutes `${VAR}` placeholders, passes to Bicep.

### 4. Main Bicep Template

**File**: `infra/main.bicep`

**Lines 100-103**: Declares parameters:

```bicep
param oidcClientId string = ''
param oidcAcrValues string = ''
param oidcPrompt string = ''
param oidcResponseType string = ''
```

**Lines 328-331**: Passes to backend module:

```bicep
module backend './app/backend-springboot.bicep' = {
  name: 'backend-springboot'
  params: {
    // ... other params
    oidcAcrValues: oidcAcrValues
    oidcPrompt: oidcPrompt
    oidcResponseType: oidcResponseType
  }
}
```

### 5. Backend Bicep Module

**File**: `infra/app/backend-springboot.bicep`

**Lines 79-81**: Receives parameters:

```bicep
param oidcAcrValues string = ''
param oidcPrompt string = ''
param oidcResponseType string = ''
```

**Lines 186-201**: Creates conditional environment variable array:

```bicep
var oidcAdditionalParamsEnv = [
  !empty(oidcAcrValues) ? {
    name: 'OIDC_ADDL_REQ_PARAM_ACR_VALUES'
    value: oidcAcrValues
  } : null
  !empty(oidcPrompt) ? {
    name: 'OIDC_ADDL_REQ_PARAM_PROMPT'
    value: oidcPrompt
  } : null
  !empty(oidcResponseType) ? {
    name: 'OIDC_ADDL_REQ_PARAM_RESPONSE_TYPE'
    value: oidcResponseType
  } : null
]

var oidcAdditionalParamsEnvFiltered = filter(oidcAdditionalParamsEnv, param => param != null)
```

**Line 236**: Merges into container environment array:

```bicep
var combinedEnv = concat(baseEnvArray, appInsightsEnv, sqlEnv, oidcEnv, oidcAdditionalParamsEnvFiltered, jwtEnv, corsEnv, envVars)
```

**Result**: Container Apps receives environment variables:
```
OIDC_ADDL_REQ_PARAM_ACR_VALUES=http://idmanagement.gov/ns/assurance/ial/1
OIDC_ADDL_REQ_PARAM_PROMPT=login
OIDC_ADDL_REQ_PARAM_RESPONSE_TYPE=code
```

### 6. Spring Boot Property Normalization

**Spring Boot automatic behavior**:

Environment variables are normalized to lowercase property keys with dots:
- `OIDC_ADDL_REQ_PARAM_ACR_VALUES` → `oidc.addl.req.param.acr.values`
- `OIDC_ADDL_REQ_PARAM_PROMPT` → `oidc.addl.req.param.prompt`
- `OIDC_ADDL_REQ_PARAM_RESPONSE_TYPE` → `oidc.addl.req.param.response.type`

**Normalization rules**:
- Uppercase → lowercase
- Underscores `_` → dots `.`

### 7. Backend Java Code

**File**: `backend/src/main/java/x/y/z/backend/security/CustomAuthorizationRequestResolver.java`

**Line 38**: Property prefix constant:

```java
private static final String PARAM_PREFIX = "oidc.addl.req.param.";
```

**Lines 57-91**: Load parameters at startup:

```java
private Map<String, String> loadAdditionalParameters() {
    Map<String, String> params = new HashMap<>();
    
    System.out.println("=== DEBUG: Checking OIDC Additional Parameters ===");
    
    // Debug: Check if environment variables exist directly
    System.out.println("Direct env check - OIDC_ADDL_REQ_PARAM_ACR_VALUES: " + 
        System.getenv("OIDC_ADDL_REQ_PARAM_ACR_VALUES"));
    System.out.println("Direct env check - OIDC_ADDL_REQ_PARAM_PROMPT: " + 
        System.getenv("OIDC_ADDL_REQ_PARAM_PROMPT"));
    System.out.println("Direct env check - OIDC_ADDL_REQ_PARAM_RESPONSE_TYPE: " + 
        System.getenv("OIDC_ADDL_REQ_PARAM_RESPONSE_TYPE"));
    
    String[] commonParams = {
        "acr_values", "prompt", "response_type", // ... others
    };
    
    for (String paramName : commonParams) {
        // Convert: acr_values -> acr.values
        String normalizedParamName = paramName.replace('_', '.');
        // Build property key: oidc.addl.req.param.acr.values
        String propertyKey = PARAM_PREFIX + normalizedParamName;
        // Get from Spring Environment (reads normalized env vars)
        String value = environment.getProperty(propertyKey);
        
        System.out.println("Checking property: " + propertyKey + " = " + value);
        
        if (value != null && !value.trim().isEmpty()) {
            params.put(paramName, value);  // Use original name for OAuth2
            System.out.println("✓ Loaded OIDC param: " + paramName + " = " + value);
        }
    }
    
    System.out.println("Total OIDC additional params loaded: " + params.size());
    return params;
}
```

**Logic**:
1. Check direct environment variables (debug)
2. For each parameter name (e.g., `acr_values`):
   - Replace `_` with `.` → `acr.values`
   - Prepend prefix → `oidc.addl.req.param.acr.values`
   - Look up property via Spring Environment
   - If found, add to map with original name (`acr_values`)

**Lines 115-135**: Add to authorization request:

```java
private OAuth2AuthorizationRequest customizeAuthorizationRequest(
        OAuth2AuthorizationRequest authorizationRequest) {
    if (authorizationRequest == null || additionalParams.isEmpty()) {
        return authorizationRequest;
    }

    Map<String, Object> additionalParameters = 
        new HashMap<>(authorizationRequest.getAdditionalParameters());
    additionalParameters.putAll(additionalParams);
    
    return OAuth2AuthorizationRequest.from(authorizationRequest)
        .additionalParameters(additionalParameters)
        .build();
}
```

### 8. OAuth2 Authorization Request

**Result**: When user clicks login, backend generates authorization URL:

```
https://idp.int.identitysandbox.gov/openid_connect/authorize
  ?client_id=urn:gov:gsa:openidconnect.profiles:sp:sso:doi:RAPTOR-Containerization
  &redirect_uri=https://dev-rap-be-...azurecontainerapps.io/login/oauth2/code/oidc-provider
  &response_type=code
  &scope=openid%20profile%20email
  &state=...
  &code_challenge=...
  &code_challenge_method=S256
  &acr_values=http://idmanagement.gov/ns/assurance/ial/1  ← CUSTOM
  &prompt=login                                           ← CUSTOM
```

## Complete Variable Name Mapping

| GitHub Variable | azd Environment | Bicep Parameter | Container Env Var | Spring Property | OAuth2 Param |
|-----------------|-----------------|-----------------|-------------------|-----------------|--------------|
| `OIDC_ADDL_REQ_PARAM_ACR_VALUES` | `OIDC_ADDL_REQ_PARAM_ACR_VALUES` | `oidcAcrValues` | `OIDC_ADDL_REQ_PARAM_ACR_VALUES` | `oidc.addl.req.param.acr.values` | `acr_values` |
| `OIDC_ADDL_REQ_PARAM_PROMPT` | `OIDC_ADDL_REQ_PARAM_PROMPT` | `oidcPrompt` | `OIDC_ADDL_REQ_PARAM_PROMPT` | `oidc.addl.req.param.prompt` | `prompt` |
| `OIDC_ADDL_REQ_PARAM_RESPONSE_TYPE` | `OIDC_ADDL_REQ_PARAM_RESPONSE_TYPE` | `oidcResponseType` | `OIDC_ADDL_REQ_PARAM_RESPONSE_TYPE` | `oidc.addl.req.param.response.type` | `response_type` |

## Verification Commands

### Check GitHub Variables
```bash
gh variable list
```

### Check azd Environment
```powershell
cd infra
azd env get-values | Select-String "OIDC_ADDL"
```

### Check Container Environment Variables
```powershell
az containerapp show -n dev-rap-be -g rg-raptor-test `
  --query "properties.template.containers[0].env[?contains(name, 'OIDC_ADDL')]" `
  -o table
```

### Check Backend Logs
```powershell
az containerapp logs show -n dev-rap-be -g rg-raptor-test --tail 100 | Select-String "DEBUG|OIDC"
```

Expected output:
```
=== DEBUG: Checking OIDC Additional Parameters ===
Direct env check - OIDC_ADDL_REQ_PARAM_ACR_VALUES: http://idmanagement.gov/ns/assurance/ial/1
Direct env check - OIDC_ADDL_REQ_PARAM_PROMPT: login
Direct env check - OIDC_ADDL_REQ_PARAM_RESPONSE_TYPE: code
Checking property: oidc.addl.req.param.acr.values = http://idmanagement.gov/ns/assurance/ial/1
✓ Loaded OIDC param: acr_values = http://idmanagement.gov/ns/assurance/ial/1
Checking property: oidc.addl.req.param.prompt = login
✓ Loaded OIDC param: prompt = login
Checking property: oidc.addl.req.param.response.type = code
✓ Loaded OIDC param: response_type = code
Total OIDC additional params loaded: 3
=== END DEBUG ===
```

### Check Authorization Request
1. Open browser DevTools (F12) → Network tab
2. Navigate to application and click login
3. Find redirect to OIDC provider
4. Right-click → Copy → Copy URL
5. Verify custom parameters are present

## Troubleshooting

### Issue: "Total OIDC additional params loaded: 0"

**Possible causes**:
1. GitHub variables not set correctly
   - **Fix**: Check variable names are exactly `OIDC_ADDL_REQ_PARAM_ACR_VALUES` (not `OIDC_ACR_VALUES`)
   
2. Workflow didn't set azd environment
   - **Fix**: Check workflow logs for "✓ OIDC_ADDL_REQ_PARAM_* configured" messages
   
3. Bicep didn't pass to container
   - **Fix**: Verify container env vars with `az containerapp show` command above
   
4. Old container revision running
   - **Fix**: Trigger infrastructure deployment to create new revision

### Issue: "Direct env check" shows null

Container environment variables are missing. Check:
1. Did workflow run after setting GitHub variables?
2. Did Bicep deployment succeed?
3. Check Bicep template has `oidcAdditionalParamsEnvFiltered` in `combinedEnv`

### Issue: Parameters appear in logs but not in authorization URL

Check `customizeAuthorizationRequest` method is being called. Enable Spring Security debug logging:
```yaml
logging:
  level:
    org.springframework.security: DEBUG
```

## Design Rationale

### Why Individual Variables Instead of JSON?

**Original approach (FAILED)**:
```json
OIDC_ADDITIONAL_PARAMS='{"acr_values":"value","prompt":"login"}'
```

Problems:
- Multiple layers of escaping (GitHub → Shell → azd → Bicep)
- Bicep `json()` function errors
- Difficult to debug
- Fragile and complex

**Current approach (SUCCESS)**:
```
OIDC_ADDL_REQ_PARAM_ACR_VALUES=value
OIDC_ADDL_REQ_PARAM_PROMPT=login
```

Benefits:
- No JSON parsing needed
- Simple string passing at every layer
- Easy to debug (can check at each step)
- Each parameter independently optional
- No escaping issues

### Why This Naming Convention?

- **GitHub**: `OIDC_ADDL_REQ_PARAM_ACR_VALUES` - Uppercase with underscores (standard)
- **azd**: Same as GitHub (pass-through)
- **Bicep parameter**: `oidcAcrValues` - camelCase (Bicep convention)
- **Container env**: `OIDC_ADDL_REQ_PARAM_ACR_VALUES` - Back to uppercase (env var standard)
- **Spring property**: `oidc.addl.req.param.acr.values` - Lowercase with dots (Spring convention)
- **OAuth2 param**: `acr_values` - Lowercase with underscores (OAuth2 spec)

Each layer uses its own convention, with automatic conversion between them.
