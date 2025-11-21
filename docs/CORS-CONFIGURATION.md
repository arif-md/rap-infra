# CORS Configuration with Credentials

## Overview

This document explains how CORS (Cross-Origin Resource Sharing) is configured in the RAP application to support credential-based authentication (cookies, JWT tokens) between the Angular frontend and Spring Boot backend services.

## Table of Contents

- [The Problem](#the-problem)
- [The Solution](#the-solution)
- [Implementation Details](#implementation-details)
- [Two-Phase Deployment Flow](#two-phase-deployment-flow)
- [Runtime Request Flow](#runtime-request-flow)
- [Adding New Backend Services](#adding-new-backend-services)
- [Troubleshooting](#troubleshooting)

---

## The Problem

### Browser CORS Requirements with Credentials

When a frontend application sends HTTP requests with `withCredentials: true` (to include cookies/auth headers), browsers enforce strict CORS security rules:

1. **Server MUST respond with `Access-Control-Allow-Credentials: true` header**
2. **Server MUST respond with specific origin** (e.g., `Access-Control-Allow-Origin: https://frontend.com`)
3. **Server CANNOT use wildcard `*`** in the origin header when credentials are enabled

**Why?** Wildcard (`*`) with credentials is a major security risk - any malicious website could steal user's cookies and tokens.

### Our Application Requirements

```typescript
// Frontend (Angular) - auth-interceptor.ts
this.http.get<Data>(url, { withCredentials: true })
```

- Frontend sends **all** API requests with `withCredentials: true`
- Frontend needs to send/receive JWT tokens in httpOnly cookies
- Browser blocks requests if CORS headers don't match requirements

### The Circular Dependency Challenge

```
Frontend needs → Backend URL (to call APIs)
Backend needs → Frontend URL (for CORS configuration)
```

**Problem**: Can't deploy either service first because each needs the other's URL at deployment time!

### Spring Boot Validation Constraint

```java
// Spring Boot enforces this validation:
if (allowedOrigins.contains("*") && allowCredentials == true) {
    throw new IllegalArgumentException(
        "When allowCredentials is true, allowedOrigins cannot contain '*'"
    );
}
```

Spring Boot **will not start** if you try to configure wildcard origins with credentials enabled.

---

## The Solution

### Two-Phase Deployment Strategy

**Phase 1: Initial Deployment**
- Deploy frontend and backend with **temporary wildcard CORS**
- Credentials temporarily disabled (`allowCredentials=false`)
- Retrieve URLs (FQDNs) from Azure after deployment
- Services are deployed but credentials don't work yet

**Phase 2: Update with Specific Origins**
- Workflow retrieves both service FQDNs
- Sets backend CORS to **specific frontend URL**
- Re-provisions backend with proper CORS configuration
- Credentials now work correctly

### Key Architectural Decisions

1. **Container Apps Ingress handles CORS at platform level**
   - Ingress CORS policy applies before requests reach the application
   - Ingress automatically substitutes wildcard with actual requesting origin in responses
   - Always configured with `allowCredentials: true`

2. **Spring Boot validates CORS at application level**
   - Receives specific frontend URL via environment variable
   - Conditional credentials: `allowCredentials = !isWildcard`
   - Provides defense-in-depth security

3. **Service-specific environment variables**
   - `BACKEND_CORS_ALLOWED_ORIGINS` for backend service
   - `PROCESS_CORS_ALLOWED_ORIGINS` for process service (future)
   - Each service can have different CORS policies

---

## Implementation Details

### 1. Container Apps Ingress CORS

**File**: `infra/modules/containerApp.bicep`

```bicep
@description('CORS Allowed Origins (comma-separated or wildcard)')
param corsAllowedOrigins string = '*'

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  properties: {
    configuration: {
      ingress: {
        corsPolicy: {
          allowedOrigins: split(corsAllowedOrigins, ',')
          allowedMethods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS']
          allowedHeaders: ['*']
          exposeHeaders: ['*']
          maxAge: 3600
          allowCredentials: true  // Always enabled - ingress handles origin substitution
        }
      }
    }
  }
}
```

**How it works**:
- Accepts comma-separated list of origins or wildcard `*`
- When wildcard is configured, ingress **automatically replaces** `*` with actual requesting origin in response
- `allowCredentials: true` is always safe at ingress level because of this substitution
- Response always contains specific origin, never wildcard

**Example**:
```
Request:  Origin: https://dev-rap-fe.whitefield-27374a4f.eastus2.azurecontainerapps.io
Config:   allowedOrigins: ['*']
Response: Access-Control-Allow-Origin: https://dev-rap-fe.whitefield-27374a4f.eastus2.azurecontainerapps.io
          Access-Control-Allow-Credentials: true
```

### 2. Spring Boot CORS Configuration

**File**: `backend/src/main/java/x/y/z/backend/security/SecurityConfig.java`

```java
@Configuration
public class SecurityConfig {
    
    @Value("${cors.allowed-origins}")
    private String[] allowedOrigins;
    
    @Bean
    public CorsConfigurationSource corsConfigurationSource() {
        CorsConfiguration configuration = new CorsConfiguration();
        
        // Allowed origins from environment variable
        configuration.setAllowedOrigins(Arrays.asList(allowedOrigins));
        
        // Allowed HTTP methods
        configuration.setAllowedMethods(
            Arrays.asList("GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS")
        );
        
        // Allowed headers
        configuration.setAllowedHeaders(Arrays.asList("*"));
        
        // Conditional credentials based on origin configuration
        // Spring Boot validation: cannot have allowCredentials=true with origins='*'
        boolean isWildcardOrigin = Arrays.asList(allowedOrigins).contains("*");
        configuration.setAllowCredentials(!isWildcardOrigin);
        
        // Expose headers to frontend
        configuration.setExposedHeaders(Arrays.asList("Authorization", "Set-Cookie"));
        
        // Cache preflight response for 1 hour
        configuration.setMaxAge(3600L);

        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/**", configuration);
        
        return source;
    }
}
```

**Key points**:
- Reads `cors.allowed-origins` from environment variable `CORS_ALLOWED_ORIGINS`
- Conditionally enables credentials: `!isWildcardOrigin`
- During Phase 1: receives `*` → credentials disabled
- During Phase 2: receives `https://frontend-url` → credentials enabled
- Provides application-level CORS validation

### 3. Backend Service Bicep Module

**File**: `infra/app/backend-springboot.bicep`

```bicep
@description('CORS Allowed Origins (comma-separated)')
param corsAllowedOrigins string = ''

// CORS environment variables for Spring Boot
var corsEnv = !empty(corsAllowedOrigins) ? [
  {
    name: 'CORS_ALLOWED_ORIGINS'
    value: corsAllowedOrigins
  }
  {
    name: 'FRONTEND_URL'
    value: frontendUrl
  }
] : []

// Combine all environment variables
var combinedEnv = concat(baseEnvArray, appInsightsEnv, sqlEnv, oidcEnv, jwtEnv, corsEnv, envVars)

module containerApp '../modules/containerApp.bicep' = {
  params: {
    corsAllowedOrigins: corsAllowedOrigins  // Pass to ingress configuration
    env: combinedEnv                         // Pass to container environment
  }
}
```

**Flow**:
1. Receives `corsAllowedOrigins` parameter from main.bicep
2. Creates `CORS_ALLOWED_ORIGINS` environment variable for Spring Boot
3. Passes same value to Container Apps ingress CORS policy
4. Both layers (ingress and application) use consistent configuration

### 4. Main Bicep Orchestration

**File**: `infra/main.bicep`

```bicep
@description('CORS Allowed Origins (comma-separated)')
param corsAllowedOrigins string = ''

// Backend service deployment
module backend './app/backend-springboot.bicep' = {
  params: {
    // CORS: Use provided origins or wildcard during initial deployment
    corsAllowedOrigins: !empty(corsAllowedOrigins) ? corsAllowedOrigins : '*'
    // ... other params
  }
}
```

**Logic**:
- If `corsAllowedOrigins` parameter provided → use it
- If empty → default to wildcard `*` (Phase 1)
- Workflow updates parameter for Phase 2 with specific frontend URL

### 5. Parameter Mapping

**File**: `infra/main.parameters.json`

```json
{
  "parameters": {
    "corsAllowedOrigins": {
      "value": "${BACKEND_CORS_ALLOWED_ORIGINS}"
    }
  }
}
```

**Service-specific naming**:
- `BACKEND_CORS_ALLOWED_ORIGINS` for backend service
- `PROCESS_CORS_ALLOWED_ORIGINS` for process service (future)
- Each backend service gets its own CORS configuration
- Prevents accidental cross-service CORS misconfiguration

### 6. GitHub Actions Workflow

**File**: `.github/workflows/provision-infrastructure.yaml`

```yaml
- name: Initial Provision
  run: |
    azd provision --no-prompt --environment "$AZURE_ENV_NAME"

- name: Update FQDNs for cross-service communication
  run: |
    # Get FQDNs from azd environment outputs
    FRONTEND_FQDN=$(azd env get-value frontendFqdn 2>/dev/null || echo "")
    BACKEND_FQDN=$(azd env get-value backendFqdn 2>/dev/null || echo "")
    
    if [ -n "$FRONTEND_FQDN" ] && [ "$FRONTEND_FQDN" != "null" ]; then
      echo "Frontend FQDN: $FRONTEND_FQDN"
      azd env set FRONTEND_FQDN "$FRONTEND_FQDN"
    fi
    
    if [ -n "$BACKEND_FQDN" ] && [ "$BACKEND_FQDN" != "null" ]; then
      echo "Backend FQDN: $BACKEND_FQDN"
      azd env set BACKEND_FQDN "$BACKEND_FQDN"
    fi
    
    # Set backend-specific CORS allowed origins to frontend URL
    if [ -n "$FRONTEND_FQDN" ] && [ "$FRONTEND_FQDN" != "null" ]; then
      echo "Setting backend CORS allowed origins to frontend URL: https://$FRONTEND_FQDN"
      azd env set BACKEND_CORS_ALLOWED_ORIGINS "https://$FRONTEND_FQDN"
    fi
    
    # Re-provision to update container apps with correct URLs and CORS
    if [ -n "$FRONTEND_FQDN" ] && [ -n "$BACKEND_FQDN" ]; then
      echo "Re-provisioning to update cross-service URLs and CORS configuration..."
      azd provision --no-prompt --environment "$AZURE_ENV_NAME"
    else
      echo "Warning: Could not retrieve FQDNs, skipping URL update"
    fi
```

**Workflow steps**:
1. **Initial provision**: Deploys both services with wildcard CORS
2. **Retrieve outputs**: Gets frontend and backend FQDNs from Azure
3. **Set environment variables**: Configures service-specific CORS URLs
4. **Re-provision**: Updates backend with specific frontend URL
5. **Result**: Backend now accepts credentials from frontend

---

## Two-Phase Deployment Flow

### Phase 1: Initial Deployment (Wildcard CORS)

```
┌─────────────────────────────────────────────────────────────┐
│ 1. azd provision (First Run)                                │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 2. Deploy Frontend                                           │
│    - Deploys Angular container                              │
│    - Azure assigns URL:                                     │
│      https://dev-rap-fe.whitefield-27374a4f.eastus2...     │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 3. Deploy Backend                                            │
│    - BACKEND_CORS_ALLOWED_ORIGINS: (empty/undefined)        │
│    - Defaults to: corsAllowedOrigins = '*'                  │
│    - Container Apps Ingress:                                │
│      * allowedOrigins: ['*']                                │
│      * allowCredentials: true                               │
│    - Spring Boot:                                            │
│      * allowedOrigins: ['*']                                │
│      * allowCredentials: false (wildcard protection)        │
│    - Azure assigns URL:                                     │
│      https://dev-rap-be.whitefield-27374a4f.eastus2...     │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 4. Deployment Outputs                                        │
│    - frontendFqdn: dev-rap-fe.whitefield-27374a4f...        │
│    - backendFqdn: dev-rap-be.whitefield-27374a4f...         │
└─────────────────────────────────────────────────────────────┘
```

**Status after Phase 1**:
- ✅ Both services deployed and accessible
- ✅ Frontend can make basic GET requests to backend
- ❌ **Credentials don't work** - Spring Boot has `allowCredentials=false`
- ❌ Frontend requests with `withCredentials: true` may fail

### Phase 2: Update with Specific Origins

```
┌─────────────────────────────────────────────────────────────┐
│ 5. Workflow Retrieves FQDNs                                  │
│    FRONTEND_FQDN=$(azd env get-value frontendFqdn)          │
│    BACKEND_FQDN=$(azd env get-value backendFqdn)            │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 6. Workflow Sets Environment Variables                       │
│    azd env set BACKEND_CORS_ALLOWED_ORIGINS \               │
│      "https://dev-rap-fe.whitefield-27374a4f..."            │
│    azd env set FRONTEND_FQDN "dev-rap-fe..."                │
│    azd env set BACKEND_FQDN "dev-rap-be..."                 │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 7. azd provision (Second Run)                                │
│    - Frontend: No changes (already has correct backend URL) │
│    - Backend: Updated with new environment variable         │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 8. Backend Re-deployed                                       │
│    - BACKEND_CORS_ALLOWED_ORIGINS: "https://dev-rap-fe..." │
│    - Container Apps Ingress:                                │
│      * allowedOrigins: ['https://dev-rap-fe...']            │
│      * allowCredentials: true                               │
│    - Spring Boot:                                            │
│      * allowedOrigins: ['https://dev-rap-fe...']            │
│      * allowCredentials: true (specific origin!)            │
│    - Environment variable in container:                     │
│      * CORS_ALLOWED_ORIGINS=https://dev-rap-fe...           │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 9. Deployment Complete                                       │
│    ✅ Both services have correct URLs                        │
│    ✅ Backend accepts credentials from frontend              │
│    ✅ CORS fully configured for production use               │
└─────────────────────────────────────────────────────────────┘
```

**Status after Phase 2**:
- ✅ Both services deployed with correct cross-references
- ✅ Backend CORS configured with specific frontend URL
- ✅ Credentials enabled at both ingress and application levels
- ✅ Frontend `withCredentials: true` requests work correctly
- ✅ Secure CORS configuration (no wildcard with credentials)

---

## Runtime Request Flow

### Successful CORS Request with Credentials

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Frontend (Angular) - User Action                         │
│    this.http.get('https://dev-rap-be.../api/applications',  │
│                  { withCredentials: true })                  │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 2. Browser - Preflight Request (OPTIONS)                    │
│    OPTIONS https://dev-rap-be.../api/applications           │
│    Origin: https://dev-rap-fe.whitefield-27374a4f...        │
│    Access-Control-Request-Method: GET                       │
│    Access-Control-Request-Headers: content-type             │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 3. Container Apps Ingress - CORS Check                      │
│    ✓ Check: Is origin in allowedOrigins?                    │
│      → Yes: https://dev-rap-fe... matches configured origin │
│    ✓ Check: Is method in allowedMethods?                    │
│      → Yes: GET is in the list                              │
│    ✓ Check: Are headers in allowedHeaders?                  │
│      → Yes: content-type is allowed (wildcard *)            │
│                                                              │
│    Response Headers Added:                                  │
│      Access-Control-Allow-Origin: https://dev-rap-fe...     │
│      Access-Control-Allow-Methods: GET,POST,PUT,DELETE...   │
│      Access-Control-Allow-Headers: content-type             │
│      Access-Control-Allow-Credentials: true                 │
│      Access-Control-Max-Age: 3600                           │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 4. Spring Boot - CORS Validation                            │
│    (Preflight request short-circuits here, no app logic)    │
│    ✓ Origin validation: https://dev-rap-fe... ∈ allowedOrigins
│    ✓ Method validation: GET ∈ allowedMethods                │
│    ✓ Headers validation: content-type ∈ allowedHeaders      │
│    ✓ Credentials allowed: allowCredentials = true           │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 5. Preflight Response to Browser                            │
│    HTTP 200 OK                                               │
│    Access-Control-Allow-Origin: https://dev-rap-fe...       │
│    Access-Control-Allow-Credentials: true                   │
│    Access-Control-Allow-Methods: GET,POST,PUT,DELETE...     │
│    Access-Control-Max-Age: 3600                             │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 6. Browser - Actual Request (GET)                           │
│    GET https://dev-rap-be.../api/applications               │
│    Origin: https://dev-rap-fe.whitefield-27374a4f...        │
│    Cookie: jwt=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...      │
│    (Cookie automatically included due to withCredentials)   │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 7. Container Apps Ingress - CORS Check (Actual Request)     │
│    ✓ Origin validated again                                 │
│    → Forwards request to backend container                  │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 8. Spring Boot - Request Processing                         │
│    ✓ CORS validation passed                                 │
│    ✓ JWT Authentication Filter validates token              │
│    ✓ Security checks passed                                 │
│    → Execute controller method                              │
│    → Query database                                         │
│    → Build response                                         │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 9. Response from Backend                                     │
│    HTTP 200 OK                                               │
│    Content-Type: application/json                           │
│    Access-Control-Allow-Origin: https://dev-rap-fe...       │
│    Access-Control-Allow-Credentials: true                   │
│    Access-Control-Expose-Headers: Authorization, Set-Cookie │
│    Set-Cookie: jwt=new_token; HttpOnly; Secure; SameSite   │
│    Body: { "applications": [...] }                          │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 10. Browser - CORS Validation                               │
│     ✓ Check: Access-Control-Allow-Origin matches request?   │
│       → Yes: https://dev-rap-fe... matches                  │
│     ✓ Check: Access-Control-Allow-Credentials present?      │
│       → Yes: true                                            │
│     ✓ CORS validation PASSED                                │
│     → Allow JavaScript to read response                     │
│     → Store new cookie for domain                           │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 11. Frontend - Response Handling                            │
│     .subscribe({                                             │
│       next: (data) => {                                      │
│         // Successfully received applications data           │
│         this.applications = data;                           │
│       }                                                      │
│     })                                                       │
└─────────────────────────────────────────────────────────────┘
```

### What Happens If CORS Fails

```
❌ Scenario: Backend configured with wildcard + credentials

Container Apps:
  allowedOrigins: ['*']
  allowCredentials: true
  
Spring Boot:
  allowedOrigins: ['*']
  allowCredentials: true  ← INVALID!

Result:
  → Spring Boot fails to start with error:
    "When allowCredentials is true, allowedOrigins cannot contain '*'"
```

```
❌ Scenario: Backend doesn't allow credentials

Container Apps:
  allowedOrigins: ['*']
  allowCredentials: false
  
Frontend sends: withCredentials: true

Browser Response:
  → Access-Control-Allow-Credentials header missing
  → Browser blocks response with CORS error:
    "Credentials flag is 'true', but the 'Access-Control-Allow-Credentials' 
     header is ''. It must be 'true' to allow credentials."
```

---

## Adding New Backend Services

When adding a new backend service (e.g., process service), follow this pattern:

### 1. Create Service-Specific Environment Variable

**File**: `infra/main.parameters.json`

```json
{
  "parameters": {
    "backendCorsAllowedOrigins": {
      "value": "${BACKEND_CORS_ALLOWED_ORIGINS}"
    },
    "processCorsAllowedOrigins": {
      "value": "${PROCESS_CORS_ALLOWED_ORIGINS}"
    }
  }
}
```

### 2. Add Parameter to Main Bicep

**File**: `infra/main.bicep`

```bicep
@description('CORS Allowed Origins for backend service')
param backendCorsAllowedOrigins string = ''

@description('CORS Allowed Origins for process service')
param processCorsAllowedOrigins string = ''

module backend './app/backend-springboot.bicep' = {
  params: {
    corsAllowedOrigins: !empty(backendCorsAllowedOrigins) ? backendCorsAllowedOrigins : '*'
  }
}

module process './app/process-service.bicep' = {
  params: {
    corsAllowedOrigins: !empty(processCorsAllowedOrigins) ? processCorsAllowedOrigins : '*'
  }
}
```

### 3. Update Workflow to Set CORS URLs

**File**: `.github/workflows/provision-infrastructure.yaml`

```yaml
# Set CORS for backend (accepts requests from frontend)
if [ -n "$FRONTEND_FQDN" ] && [ "$FRONTEND_FQDN" != "null" ]; then
  echo "Setting backend CORS to frontend URL: https://$FRONTEND_FQDN"
  azd env set BACKEND_CORS_ALLOWED_ORIGINS "https://$FRONTEND_FQDN"
fi

# Set CORS for process service (accepts requests from backend)
if [ -n "$BACKEND_FQDN" ] && [ "$BACKEND_FQDN" != "null" ]; then
  echo "Setting process service CORS to backend URL: https://$BACKEND_FQDN"
  azd env set PROCESS_CORS_ALLOWED_ORIGINS "https://$BACKEND_FQDN"
fi
```

### 4. CORS Flow with Multiple Services

```
┌──────────┐                    ┌──────────┐                    ┌──────────┐
│ Frontend │ withCredentials    │ Backend  │ withCredentials    │ Process  │
│ Angular  │ ────────────────→  │ Spring   │ ────────────────→  │ Service  │
└──────────┘                    └──────────┘                    └──────────┘
     ↓                               ↓                               ↓
CORS config:                   CORS config:                   CORS config:
- Origins: backend URL         - Origins: frontend URL        - Origins: backend URL
- Credentials: true            - Credentials: true            - Credentials: true
```

**Key principle**: Each service's CORS configuration lists the origins of services that will call it:
- **Backend**: Allows frontend URL (browser-to-backend calls)
- **Process**: Allows backend URL (backend-to-process calls)
- **Frontend**: No CORS config needed (browsers don't enforce CORS for requests TO the origin)

---

## Troubleshooting

### Error: "When allowCredentials is true, allowedOrigins cannot contain '*'"

**Symptom**: Backend container fails to start, logs show Spring Boot error

**Cause**: Backend received wildcard `*` in `CORS_ALLOWED_ORIGINS` environment variable

**Solution**:
1. Check if second provision completed: `azd env get-value BACKEND_CORS_ALLOWED_ORIGINS`
2. If empty or `*`, manually set: `azd env set BACKEND_CORS_ALLOWED_ORIGINS "https://<frontend-fqdn>"`
3. Re-provision: `azd provision`

### Error: Browser CORS error "Credentials flag is 'true', but header is missing"

**Symptom**: Frontend shows CORS error in browser console, requests blocked

**Cause**: Backend not responding with `Access-Control-Allow-Credentials: true`

**Diagnosis**:
```powershell
# Test CORS preflight
$frontend = az containerapp show --name dev-rap-fe --resource-group rg-raptor-test --query "properties.configuration.ingress.fqdn" -o tsv
$backend = az containerapp show --name dev-rap-be --resource-group rg-raptor-test --query "properties.configuration.ingress.fqdn" -o tsv

curl -I -X OPTIONS "https://$backend/api/applications" `
  -H "Origin: https://$frontend" `
  -H "Access-Control-Request-Method: GET"
```

**Look for**:
- `access-control-allow-credentials: true` ✓
- `access-control-allow-origin: https://<frontend-fqdn>` ✓ (NOT `*`)

**Solution if missing**:
1. Verify ingress CORS: `az containerapp ingress cors show --name dev-rap-be --resource-group rg-raptor-test`
2. Check `allowCredentials` is `true`
3. Check backend environment: `az containerapp show --name dev-rap-be --query "properties.template.containers[0].env"`
4. Verify `CORS_ALLOWED_ORIGINS` has specific URL (not `*`)

### Error: "Origin is not allowed by Access-Control-Allow-Origin"

**Symptom**: Browser blocks request, shows origin mismatch error

**Cause**: Backend CORS configured with different URL than frontend is using

**Diagnosis**:
```powershell
# Get actual frontend URL
$frontend = az containerapp show --name dev-rap-fe --resource-group rg-raptor-test --query "properties.configuration.ingress.fqdn" -o tsv
echo "Frontend URL: https://$frontend"

# Get backend CORS config
az containerapp show --name dev-rap-be --resource-group rg-raptor-test --query "properties.template.containers[0].env[?name=='CORS_ALLOWED_ORIGINS'].value" -o tsv
```

**Solution**:
1. Ensure URLs match exactly (including protocol `https://`)
2. Update if mismatch: `azd env set BACKEND_CORS_ALLOWED_ORIGINS "https://$frontend"`
3. Re-provision: `azd provision`

### Workflow doesn't run second provision

**Symptom**: After deployment, backend still has wildcard CORS

**Cause**: Workflow "Update FQDNs" step skipped or failed

**Diagnosis**:
1. Check workflow logs for "Update FQDNs" step
2. Look for error messages about missing FQDNs
3. Check if outputs exist: `azd env get-value frontendFqdn`

**Solution**:
1. Manually trigger second provision:
   ```bash
   FRONTEND_FQDN=$(azd env get-value frontendFqdn)
   azd env set BACKEND_CORS_ALLOWED_ORIGINS "https://$FRONTEND_FQDN"
   azd provision
   ```

### Testing CORS Configuration

**Quick test script**:
```powershell
# Get service URLs
$frontend = az containerapp show --name dev-rap-fe --resource-group rg-raptor-test --query "properties.configuration.ingress.fqdn" -o tsv
$backend = az containerapp show --name dev-rap-be --resource-group rg-raptor-test --query "properties.configuration.ingress.fqdn" -o tsv

Write-Host "Frontend: https://$frontend"
Write-Host "Backend:  https://$backend"
Write-Host ""

# Test CORS preflight
Write-Host "Testing CORS preflight..."
curl -I -X OPTIONS "https://$backend/api/applications" `
  -H "Origin: https://$frontend" `
  -H "Access-Control-Request-Method: GET" `
  -H "Access-Control-Request-Headers: content-type"

Write-Host ""
Write-Host "Expected headers:"
Write-Host "✓ access-control-allow-origin: https://$frontend"
Write-Host "✓ access-control-allow-credentials: true"
Write-Host "✓ access-control-allow-methods: GET,POST,PUT,DELETE,PATCH,OPTIONS"
```

---

## Security Considerations

### Why Not Use Wildcard Everywhere?

```
❌ INSECURE:
allowedOrigins: '*'
allowCredentials: true

Vulnerability:
- Malicious website https://evil.com loads in user's browser
- Evil site makes request to https://your-backend.com/api/user
- Browser includes user's authentication cookies
- Backend responds with user's private data
- Evil site steals user data
```

### Defense-in-Depth

1. **Container Apps Ingress CORS**: First layer of defense
2. **Spring Boot CORS**: Second layer of defense
3. **JWT Token Validation**: Third layer (validates token contents)
4. **HttpOnly Cookies**: Prevents JavaScript access to tokens
5. **Secure Flag**: Only sends cookies over HTTPS
6. **SameSite=Strict**: Prevents CSRF attacks

### Production Best Practices

1. **Never use wildcard with credentials** in production
2. **Always specify exact origins** after initial deployment
3. **Use service-specific CORS configs** for each backend service
4. **Monitor CORS errors** in application logs and Azure Monitor
5. **Test CORS configuration** after each deployment
6. **Document allowed origins** in infrastructure code comments
7. **Review CORS configuration** during security audits

### Allowed Origins Format

```
✅ CORRECT:
https://dev-rap-fe.whitefield-27374a4f.eastus2.azurecontainerapps.io
https://test-rap-fe.whitefield-27374a4f.eastus2.azurecontainerapps.io

❌ INCORRECT:
*.azurecontainerapps.io                    (wildcards in domain)
http://dev-rap-fe...                       (http instead of https)
https://dev-rap-fe.../                     (trailing slash)
dev-rap-fe.whitefield-27374a4f...          (missing protocol)
```

### Multiple Origins

If frontend needs to be accessible from multiple domains:

```bicep
// Comma-separated list
param backendCorsAllowedOrigins string = 'https://app.example.com,https://www.example.com'

// In Spring Boot, will become array: ['https://app.example.com', 'https://www.example.com']
```

---

## References

### Documentation
- [MDN: Cross-Origin Resource Sharing (CORS)](https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS)
- [Spring Boot CORS Configuration](https://spring.io/guides/gs/rest-service-cors/)
- [Azure Container Apps: CORS](https://learn.microsoft.com/en-us/azure/container-apps/cors)

### Related Files
- `infra/modules/containerApp.bicep` - Container Apps CORS configuration
- `infra/app/backend-springboot.bicep` - Backend service deployment
- `infra/main.bicep` - Infrastructure orchestration
- `infra/main.parameters.json` - Parameter mappings
- `backend/src/main/java/x/y/z/backend/security/SecurityConfig.java` - Spring Boot CORS
- `.github/workflows/provision-infrastructure.yaml` - Deployment workflow

### Architecture Diagrams
- See `ARCHITECTURE-STRATEGIES.md` for overall architecture decisions
- See `FRONTEND-SERVICE.md` for frontend deployment details
- See `BACKEND-SERVICE.md` for backend deployment details

---

## Summary

**The Problem**: Frontend needs to send credentials (cookies, tokens) to backend, but CORS with credentials requires specific origins (not wildcard) which creates circular dependency at deployment time.

**The Solution**: Two-phase deployment:
1. Initial deploy with wildcard CORS (credentials disabled)
2. Update with specific URLs (credentials enabled)

**Key Components**:
- Container Apps Ingress CORS (platform level)
- Spring Boot CORS configuration (application level)
- Service-specific environment variables
- Workflow automation for two-phase deployment

**Result**: Secure, credential-enabled CORS that scales to multiple backend services while maintaining proper security boundaries.
