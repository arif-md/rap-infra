# OIDC Configuration for Azure Deployment

This guide explains how to configure OIDC authentication for the RAP application when deploying to Azure Container Apps.

## Overview

The infrastructure uses **Azure Key Vault** to securely store sensitive OIDC and JWT secrets. The backend Container App is granted access to retrieve these secrets at runtime.

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

## Required Environment Variables

Before deploying with `azd up`, you must set the following environment variables:

### OIDC Provider Configuration

```powershell
# Set OIDC endpoints (example for Keycloak)
azd env set OIDC_AUTHORIZATION_ENDPOINT "https://your-keycloak.com/realms/your-realm/protocol/openid-connect/auth"
azd env set OIDC_TOKEN_ENDPOINT "https://your-keycloak.com/realms/your-realm/protocol/openid-connect/token"
azd env set OIDC_USER_INFO_ENDPOINT "https://your-keycloak.com/realms/your-realm/protocol/openid-connect/userinfo"
azd env set OIDC_JWK_SET_URI "https://your-keycloak.com/realms/your-realm/protocol/openid-connect/certs"

# Set OIDC client credentials
azd env set OIDC_CLIENT_ID "raptor-app-client"
azd env set OIDC_CLIENT_SECRET "your-client-secret-from-oidc-provider"
```

**For Azure AD (Entra ID):**
```powershell
azd env set OIDC_AUTHORIZATION_ENDPOINT "https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/authorize"
azd env set OIDC_TOKEN_ENDPOINT "https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/token"
azd env set OIDC_USER_INFO_ENDPOINT "https://graph.microsoft.com/oidc/userinfo"
azd env set OIDC_JWK_SET_URI "https://login.microsoftonline.com/{tenant-id}/discovery/v2.0/keys"
azd env set OIDC_CLIENT_ID "{application-client-id}"
azd env set OIDC_CLIENT_SECRET "{application-client-secret}"
```

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
   - Add: `https://<backend-fqdn>/auth/callback`

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

## Local Development vs Azure

| Configuration | Local (docker-compose) | Azure (Container Apps) |
|--------------|------------------------|------------------------|
| **OIDC Secret** | `.env` file | Key Vault secret |
| **JWT Secret** | `.env` file | Key Vault secret |
| **Secret Access** | File system | Managed Identity → Key Vault |
| **CORS Origins** | `http://localhost:4200` | Deployed frontend URL |
| **Frontend URL** | `http://localhost:4200` | `https://<frontend-fqdn>` |

**Recommendation:** Use separate OIDC clients for local development and Azure environments.

## Next Steps

- [ ] Configure Azure AD/Entra ID as OIDC provider
- [ ] Set up Key Vault secret rotation policy
- [ ] Configure Azure Monitor alerts for Key Vault access failures
- [ ] Implement secret versioning for zero-downtime updates
- [ ] Add Application Insights monitoring for authentication flows

## References

- [Azure Key Vault Documentation](https://learn.microsoft.com/azure/key-vault/)
- [Container Apps Managed Identity](https://learn.microsoft.com/azure/container-apps/managed-identity)
- [OAuth2/OIDC Best Practices](https://datatracker.ietf.org/doc/html/rfc6749)
- [JWT Secret Best Practices](https://auth0.com/docs/secure/tokens/json-web-tokens/json-web-token-best-practices)

---

**Document Version:** 1.0  
**Last Updated:** 2025-11-05  
**Maintained By:** RAP Development Team
