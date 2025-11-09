# OIDC Configuration Guide

This guide explains how to configure OIDC authentication for the RAP application in both **local development** (Docker with Keycloak) and **Azure deployment** (Container Apps with external custom OIDC provider).

## Overview

The RAP application uses **explicit OIDC endpoint configuration** to support flexible authentication across environments:

- **Local Development**: Uses Docker-based Keycloak with split-horizon DNS (localhost:9090 for browser, keycloak:9090 for backend container)
- **Azure Production**: Uses external custom OIDC provider (hosted outside Azure) with unified HTTPS endpoints

The infrastructure uses **Azure Key Vault** to securely store sensitive OIDC and JWT secrets. The backend Container App is granted access to retrieve these secrets at runtime via managed identity.

## Architecture

```
┌─────────────────────┐
│   Azure Key Vault   │
│  ┌───────────────┐  │
│  │ oidc-client-  │  │
│  │   secret      │  │
│  └───────────────┘  │
│  ┌───────────────┐  │
│  │  jwt-secret   │  │
│  └───────────────┘  │
└──────────┬──────────┘
           │
           │ Managed Identity
           │ (Get Secrets Permission)
           │
           ▼
┌─────────────────────┐
│  Backend Container  │
│       App           │
│  ┌───────────────┐  │
│  │ Environment   │  │
│  │  Variables:   │  │
│  │ OIDC_*        │  │
│  │ JWT_*         │  │
│  └───────────────┘  │
└─────────────────────┘
```

## Configuration by Environment

### Local Development (Docker Compose)

Local development uses Keycloak running in Docker with **explicit endpoint configuration** to solve Docker networking constraints.

**Why explicit endpoints?** In Docker, the backend container cannot use `localhost:9090` to reach Keycloak because `localhost` refers to the container itself. We use separate URLs:
- **Authorization endpoint**: `http://localhost:9090` (for browser redirects)
- **Backend-to-Keycloak endpoints**: `http://keycloak:9090` (internal Docker network)

**Configuration in `.env` file:**
```properties
# OIDC Provider Issuer URI - Leave EMPTY to use explicit endpoints
OIDC_PROVIDER_ISSUER_URI=

# Explicit OIDC endpoints (required for Docker networking)
OIDC_AUTHORIZATION_ENDPOINT=http://localhost:9090/realms/raptor/protocol/openid-connect/auth
OIDC_TOKEN_ENDPOINT=http://keycloak:9090/realms/raptor/protocol/openid-connect/token
OIDC_USER_INFO_ENDPOINT=http://keycloak:9090/realms/raptor/protocol/openid-connect/userinfo
OIDC_JWK_SET_URI=http://keycloak:9090/realms/raptor/protocol/openid-connect/certs

# OIDC client credentials (from Keycloak admin console)
OIDC_CLIENT_ID=raptor-client
OIDC_CLIENT_SECRET=QBkqpwoYU8xhFomyxOvUIbhPR2tIoAQt

# CORS and Frontend URLs
CORS_ALLOWED_ORIGINS=http://localhost:4200,http://localhost:3000
FRONTEND_URL=http://localhost:4200
```

**Key Points:**
- `OIDC_PROVIDER_ISSUER_URI` is intentionally empty to prevent auto-discovery failures
- Authorization endpoint uses `localhost:9090` so browser can redirect
- Token/UserInfo/JWK endpoints use `keycloak:9090` for backend-to-Keycloak communication
- See `backend/.env.example` for complete local configuration

### Azure Deployment (Custom External OIDC Provider)

Azure deployment uses an **external custom OIDC provider** hosted outside of Azure. Since both browser and backend can reach the same HTTPS URL, configuration is simpler.

**Required azd Environment Variables:**

```powershell
# Set OIDC endpoints (example for custom OIDC provider)
azd env set OIDC_AUTHORIZATION_ENDPOINT "https://your-oidc-provider.example.com/oauth2/authorize"
azd env set OIDC_TOKEN_ENDPOINT "https://your-oidc-provider.example.com/oauth2/token"
azd env set OIDC_USER_INFO_ENDPOINT "https://your-oidc-provider.example.com/oauth2/userinfo"
azd env set OIDC_JWK_SET_URI "https://your-oidc-provider.example.com/oauth2/jwks"

# Set OIDC client credentials (from your OIDC provider)
azd env set OIDC_CLIENT_ID "raptor-azure-client"
azd env set OIDC_CLIENT_SECRET "your-production-client-secret"
```

**Alternative: Azure AD (Entra ID)** (if you switch to Microsoft's identity platform):
```powershell
azd env set OIDC_AUTHORIZATION_ENDPOINT "https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/authorize"
azd env set OIDC_TOKEN_ENDPOINT "https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/token"
azd env set OIDC_USER_INFO_ENDPOINT "https://graph.microsoft.com/oidc/userinfo"
azd env set OIDC_JWK_SET_URI "https://login.microsoftonline.com/{tenant-id}/discovery/v2.0/keys"
azd env set OIDC_CLIENT_ID "{application-client-id}"
azd env set OIDC_CLIENT_SECRET "{application-client-secret}"
```

**Key Points:**
- All endpoints use the same base URL (no split-horizon needed)
- HTTPS endpoints are accessible from both browser and backend Container Apps
- Use separate OIDC client for production (different client ID and secret from local)
- Configure redirect URI in your OIDC provider: `https://<backend-fqdn>.azurecontainerapps.io/auth/callback`

### JWT Configuration

```powershell
# Generate a strong random secret (256-bit recommended)
azd env set JWT_SECRET "your-generated-secret-key-at-least-256-bits-long"

# Optional: Override default JWT settings
azd env set JWT_ISSUER "raptor-app"
azd env set JWT_ACCESS_TOKEN_EXPIRATION_MINUTES "15"
azd env set JWT_REFRESH_TOKEN_EXPIRATION_DAYS "7"
```

**Generate a secure JWT secret (PowerShell):**
```powershell
# Generate a 256-bit random secret
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$jwtSecret = [Convert]::ToBase64String($bytes)
azd env set JWT_SECRET $jwtSecret
```

### CORS Configuration

```powershell
# Set allowed origins for CORS (comma-separated)
azd env set CORS_ALLOWED_ORIGINS "https://your-frontend-app.azurecontainerapps.io,http://localhost:4200"
```

## Deployment Flow

### 1. Environment Setup

```powershell
cd infra
azd env new dev
azd env set AZURE_SUBSCRIPTION_ID <your-subscription-id>
azd env set AZURE_ENV_NAME dev
azd env set AZURE_RESOURCE_GROUP rg-raptor-dev
azd env set AZURE_ACR_NAME ngraptordev

# Set all OIDC and JWT environment variables (see above)
```

### 2. Deploy Infrastructure

```powershell
azd up
```

**What happens during deployment:**

1. **Key Vault Creation**
   - Azure Key Vault is created: `kv-{resource-token}`
   - Two secrets are stored:
     - `oidc-client-secret` (from `OIDC_CLIENT_SECRET`)
     - `jwt-secret` (from `JWT_SECRET`)

2. **Backend Identity Creation**
   - User-assigned managed identity created for backend
   - Identity granted `Get` and `List` permissions on Key Vault secrets

3. **Backend Container App Deployment**
   - Environment variables configured with Key Vault secret references:
     ```yaml
     OIDC_CLIENT_SECRET: secretRef(oidc-client-secret)
     JWT_SECRET: secretRef(jwt-secret)
     ```
   - OIDC endpoints set as plain environment variables (not secret)
   - Frontend URL automatically set to deployed frontend FQDN

4. **Secret Resolution**
   - Container App fetches secrets from Key Vault at runtime
   - Spring Boot application reads from environment variables

### 3. Verify Deployment

```powershell
# Get backend URL
azd env get-value backendFqdn

# Test authentication endpoint
curl https://<backend-fqdn>/auth/login
# Should return: { "authorizationUrl": "https://..." }
```

## Environment Variables Reference

### Container App Environment Variables (Set by Bicep)

| Variable | Source | Description |
|----------|--------|-------------|
| `OIDC_AUTHORIZATION_ENDPOINT` | Parameter | OIDC authorization endpoint URL |
| `OIDC_TOKEN_ENDPOINT` | Parameter | OIDC token endpoint URL |
| `OIDC_USER_INFO_ENDPOINT` | Parameter | OIDC user info endpoint URL |
| `OIDC_JWK_SET_URI` | Parameter | OIDC JWK set URI |
| `OIDC_CLIENT_ID` | Parameter | OIDC client ID |
| `OIDC_CLIENT_SECRET` | Key Vault Secret | OIDC client secret (from Key Vault) |
| `JWT_SECRET` | Key Vault Secret | JWT signing secret (from Key Vault) |
| `JWT_ISSUER` | Parameter | JWT issuer (default: `raptor-app`) |
| `JWT_ACCESS_TOKEN_EXPIRATION_MINUTES` | Parameter | Access token TTL (default: 15 min) |
| `JWT_REFRESH_TOKEN_EXPIRATION_DAYS` | Parameter | Refresh token TTL (default: 7 days) |
| `CORS_ALLOWED_ORIGINS` | Parameter | CORS allowed origins (comma-separated) |
| `FRONTEND_URL` | Computed | Frontend URL (auto-set to deployed frontend FQDN) |

## Security Best Practices

### Secret Management

✅ **DO:**
- Store secrets in Azure Key Vault (automatically configured)
- Use user-assigned managed identity for Key Vault access
- Rotate secrets regularly (use Key Vault secret versions)
- Use different secrets for dev/test/prod environments

❌ **DON'T:**
- Hardcode secrets in Bicep files
- Commit secrets to Git (even in `.env` files)
- Use the same JWT secret across environments
- Share OIDC client secrets between apps

### JWT Secret Requirements

- **Minimum length:** 256 bits (32 bytes)
- **Format:** Base64-encoded random bytes
- **Rotation:** Change quarterly or after suspected compromise
- **Storage:** Only in Azure Key Vault (never in code or logs)

### OIDC Client Secret

- **Source:** Obtained from your OIDC provider (Keycloak, Azure AD, etc.)
- **Permissions:** Grant minimal scopes required (openid, profile, email)
- **Rotation:** Follow your OIDC provider's rotation policy

## Updating Secrets

### Update OIDC Client Secret

```powershell
# Update the azd environment variable
azd env set OIDC_CLIENT_SECRET "new-client-secret"

# Redeploy (only Key Vault and backend affected)
azd up
```

**Note:** Container Apps will automatically pick up the new secret from Key Vault on next restart.

### Update JWT Secret

```powershell
# Generate new secret
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$newJwtSecret = [Convert]::ToBase64String($bytes)

# Update environment
azd env set JWT_SECRET $newJwtSecret

# Redeploy
azd up
```

**⚠️ WARNING:** Changing JWT secret invalidates all existing access tokens. Users must re-authenticate.

## Troubleshooting

### Issue: Container App can't access Key Vault

**Symptoms:**
- Backend logs show "Access denied" errors
- Application fails to start

**Solution:**
1. Check managed identity has Key Vault access:
   ```powershell
   az keyvault show --name <kv-name> --query properties.accessPolicies
   ```

2. Verify backend identity principal ID matches Key Vault access policy:
   ```powershell
   azd env get-value backendIdentityPrincipalId
   ```

3. Wait 5-10 minutes for Azure RBAC propagation

### Issue: OIDC authentication fails

**Symptoms:**
- `/auth/callback` returns 401 or 500
- Logs show "Invalid token" or "Invalid client"
- Browser shows CORS errors when redirecting to OIDC provider

**Solution:**
1. Verify OIDC endpoints are correct:
   ```powershell
   azd env get-value backendFqdn
   # Visit https://<backend-fqdn>/auth/login
   # Check if authorizationUrl points to correct OIDC provider
   ```

2. Verify OIDC client secret matches provider:
   ```powershell
   # Check Key Vault secret value
   az keyvault secret show --vault-name <kv-name> --name oidc-client-secret --query value
   ```

3. Check OIDC provider redirect URI configuration:
   - **Azure**: Add `https://<backend-fqdn>/auth/callback`
   - **Local**: Add `http://localhost:8080/auth/callback`
   - Ensure exact URL match (including protocol and port)

4. Verify OIDC provider allows CORS from your frontend:
   - **Azure**: Add `https://<frontend-fqdn>` to allowed origins
   - **Local**: Add `http://localhost:4200` to allowed origins

### Issue: Local Docker - Backend can't connect to Keycloak

**Symptoms:**
- Backend logs show "Connection refused" to `localhost:9090`
- Spring Boot fails to start with "Unable to resolve Configuration"
- Error: `ResourceAccessException: I/O error on GET request for "http://localhost:9090/..."`

**Root Cause:** 
Backend container's `localhost` refers to the container itself, not the host machine where Keycloak runs.

**Solution:**
1. Verify `.env` uses explicit endpoint configuration:
   ```properties
   OIDC_PROVIDER_ISSUER_URI=
   OIDC_TOKEN_ENDPOINT=http://keycloak:9090/realms/raptor/protocol/openid-connect/token
   OIDC_USER_INFO_ENDPOINT=http://keycloak:9090/realms/raptor/protocol/openid-connect/userinfo
   OIDC_JWK_SET_URI=http://keycloak:9090/realms/raptor/protocol/openid-connect/certs
   ```

2. Ensure Docker network allows backend → keycloak communication:
   ```powershell
   docker network inspect backend_default
   # Should show both rap-backend and rap-keycloak containers
   ```

3. Test Keycloak connectivity from backend container:
   ```powershell
   docker exec rap-backend curl -v http://keycloak:9090/realms/raptor/.well-known/openid-configuration
   # Should return 200 OK with OIDC configuration JSON
   ```

4. Rebuild backend if configuration changed:
   ```powershell
   cd backend
   .\dev.ps1 Dev-Rebuild
   ```

### Issue: JWT validation fails

**Symptoms:**
- API requests return 401 Unauthorized
- Logs show "Invalid signature" or "Token expired"

**Solution:**
1. Verify JWT secret is consistent:
   ```powershell
   az keyvault secret show --vault-name <kv-name> --name jwt-secret --query value
   ```

2. Check token expiration settings are reasonable:
   ```powershell
   azd env get-values | Select-String JWT
   ```

3. Clear browser cookies and re-authenticate

## Configuration Comparison: Local vs Azure

| Configuration | Local (docker-compose) | Azure (Container Apps) |
|--------------|------------------------|------------------------|
| **OIDC Provider** | Local Keycloak (Docker) | External Custom OIDC Provider |
| **OIDC Protocol** | HTTP | HTTPS |
| **OIDC Issuer URI** | Empty (explicit endpoints) | Empty (explicit endpoints) |
| **Authorization Endpoint** | `http://localhost:9090/...` | `https://your-oidc-provider.com/...` |
| **Token Endpoint** | `http://keycloak:9090/...` (internal) | `https://your-oidc-provider.com/...` (same) |
| **UserInfo Endpoint** | `http://keycloak:9090/...` (internal) | `https://your-oidc-provider.com/...` (same) |
| **JWK Set URI** | `http://keycloak:9090/...` (internal) | `https://your-oidc-provider.com/...` (same) |
| **Split-Horizon DNS** | Yes (localhost vs keycloak) | No (unified HTTPS URL) |
| **OIDC Client ID** | `raptor-client` | `raptor-azure-client` |
| **OIDC Secret Storage** | `.env` file | Azure Key Vault |
| **JWT Secret Storage** | `.env` file | Azure Key Vault |
| **Secret Access** | File system | Managed Identity → Key Vault |
| **CORS Origins** | `http://localhost:4200` | `https://<frontend-fqdn>` |
| **Frontend URL** | `http://localhost:4200` | `https://<frontend-fqdn>` |
| **Backend Base URL** | `http://localhost:8080` | `https://<backend-fqdn>` |
| **Network Constraints** | Docker internal network | Public internet (HTTPS) |

**Key Architectural Differences:**

1. **Local Docker Networking**
   - Backend container cannot reach host's `localhost`
   - Requires split-horizon: browser → `localhost:9090`, backend → `keycloak:9090`
   - Solved with explicit endpoint configuration

2. **Azure Unified Networking**
   - Both browser and backend use same HTTPS URLs
   - No Docker hostname resolution issues
   - Simpler configuration (same URL for all endpoints)

3. **Security Model**
   - **Local**: Development secrets in `.env` file (not committed to Git)
   - **Azure**: Production secrets in Key Vault with managed identity access

**Recommendation:** 
- Use **separate OIDC clients** for local development and Azure environments
- Configure different redirect URIs for each environment
- Never reuse production OIDC client secrets in local development

## OIDC Provider Setup Checklist

### For Local Development (Keycloak)

- [ ] Start Keycloak: `cd backend; .\dev.ps1 Dev-Full`
- [ ] Access Keycloak admin console: http://localhost:9090/admin (admin/admin)
- [ ] Create realm: `raptor`
- [ ] Create client: `raptor-client`
  - Client authentication: ON
  - Valid redirect URIs: `http://localhost:8080/auth/callback`
  - Valid post logout redirect URIs: `http://localhost:4200`
  - Web origins: `http://localhost:4200`, `http://localhost:8080`
- [ ] Copy client secret to `.env` file
- [ ] Verify configuration: `curl http://localhost:9090/realms/raptor/.well-known/openid-configuration`

### For Azure Deployment (Custom OIDC Provider)

- [ ] Configure OIDC client in your external provider
  - Client name: `raptor-azure-client` (or your preference)
  - Redirect URI: `https://<backend-fqdn>.azurecontainerapps.io/auth/callback`
  - Allowed origins: `https://<frontend-fqdn>.azurecontainerapps.io`
  - Scopes: `openid`, `profile`, `email`
- [ ] Note down all OIDC endpoint URLs from provider documentation
- [ ] Set azd environment variables (see "Azure Deployment" section above)
- [ ] Verify provider accessibility: `curl https://your-oidc-provider.com/.well-known/openid-configuration`
- [ ] Deploy to Azure: `cd infra; azd up`
- [ ] Test authentication: Visit `https://<backend-fqdn>/auth/login`

## Implementation Details

### Spring Boot Configuration

The backend uses **explicit endpoint configuration** instead of issuer-uri auto-discovery:

**File**: `backend/src/main/resources/application.properties`
```properties
# OIDC Provider - Issuer URI (leave empty for explicit endpoints)
spring.security.oauth2.client.provider.oidc-provider.issuer-uri=${OIDC_PROVIDER_ISSUER_URI:}

# Explicit endpoints (used when issuer-uri is empty)
spring.security.oauth2.client.provider.oidc-provider.authorization-uri=${OIDC_AUTHORIZATION_ENDPOINT:}
spring.security.oauth2.client.provider.oidc-provider.token-uri=${OIDC_TOKEN_ENDPOINT:}
spring.security.oauth2.client.provider.oidc-provider.user-info-uri=${OIDC_USER_INFO_ENDPOINT:}
spring.security.oauth2.client.provider.oidc-provider.jwk-set-uri=${OIDC_JWK_SET_URI:}
```

**Benefits of explicit configuration:**
- No auto-discovery HTTP calls during Spring Boot startup
- Works in Docker environments with split-horizon DNS
- Explicit control over each endpoint URL
- Better debugging (clear which URLs are being used)

### Infrastructure Configuration

**File**: `infra/main.bicep`
```bicep
// OIDC parameters (explicit endpoints)
param oidcAuthorizationEndpoint string = ''
param oidcTokenEndpoint string = ''
param oidcUserInfoEndpoint string = ''
param oidcJwkSetUri string = ''
param oidcClientId string = ''
@secure()
param oidcClientSecret string = ''
```

**File**: `infra/main.parameters.json`
```json
"oidcAuthorizationEndpoint": { "value": "${OIDC_AUTHORIZATION_ENDPOINT}" },
"oidcTokenEndpoint": { "value": "${OIDC_TOKEN_ENDPOINT}" },
"oidcUserInfoEndpoint": { "value": "${OIDC_USER_INFO_ENDPOINT}" },
"oidcJwkSetUri": { "value": "${OIDC_JWK_SET_URI}" },
"oidcClientId": { "value": "${OIDC_CLIENT_ID}" },
"oidcClientSecret": { "value": "${OIDC_CLIENT_SECRET}" }
```

## Next Steps

- [ ] Configure external custom OIDC provider for Azure
- [ ] Set up Key Vault secret rotation policy
- [ ] Configure Azure Monitor alerts for Key Vault access failures
- [ ] Implement secret versioning for zero-downtime updates
- [ ] Add Application Insights monitoring for authentication flows
- [ ] Document custom OIDC provider specific configuration
- [ ] Set up automated testing for authentication flows

## References

### Documentation
- [Local Keycloak Setup Guide](../../backend/docs/KEYCLOAK-LOCAL-SETUP.md)
- [Azure Key Vault Documentation](https://learn.microsoft.com/azure/key-vault/)
- [Container Apps Managed Identity](https://learn.microsoft.com/azure/container-apps/managed-identity)
- [OAuth2/OIDC Best Practices](https://datatracker.ietf.org/doc/html/rfc6749)
- [JWT Secret Best Practices](https://auth0.com/docs/secure/tokens/json-web-tokens/json-web-token-best-practices)

### Related Files
- Backend OIDC Config: `backend/.env.example`
- Backend Properties: `backend/src/main/resources/application.properties`
- Infrastructure: `infra/main.bicep`, `infra/app/backend-springboot.bicep`
- Parameters: `infra/main.parameters.json`

---

**Document Version:** 2.0  
**Last Updated:** 2025-11-07  
**Changes:** Updated for explicit OIDC endpoint configuration, added local Docker networking section, clarified external custom OIDC provider setup  
**Maintained By:** RAP Development Team
