// ============================================================================
// Azure App Configuration — Centralized Configuration Store
// ============================================================================
// Stores non-secret configuration values (OIDC, AAD, JWT, CORS, frontend).
// Secrets remain in Key Vault via Container App secretRef.
//
// Spring Boot reads these properties at startup via:
//   spring-cloud-azure-starter-appconfiguration-config
// ============================================================================

@description('App Configuration store name')
param name string

@description('Azure region')
param location string = resourceGroup().location

@description('Resource tags')
param tags object = {}

@description('App Configuration SKU (free or standard)')
@allowed(['free', 'standard'])
param sku string = 'free'

@description('Soft-delete retention in days (1-7). Lower = faster name reuse after azd down.')
@minValue(1)
@maxValue(7)
param softDeleteRetentionInDays int = 1

@description('Enable purge protection (prevents permanent deletion during retention period)')
param enablePurgeProtection bool = false

@description('Principal ID to grant App Configuration Data Reader role (backend managed identity)')
param readerPrincipalId string

// ---------------------------------------------------------------------------
// OIDC Provider (Login.gov / Keycloak) configuration
// ---------------------------------------------------------------------------
@description('OIDC Provider Authorization Endpoint URL')
param oidcAuthorizationEndpoint string = ''

@description('OIDC Provider Token Endpoint URL')
param oidcTokenEndpoint string = ''

@description('OIDC Provider User Info Endpoint URL')
param oidcUserInfoEndpoint string = ''

@description('OIDC Provider JWK Set URI')
param oidcJwkSetUri string = ''

@description('OIDC Provider End Session Endpoint (logout)')
param oidcEndSessionEndpoint string = ''

@description('OIDC Client ID (public client — PKCE)')
param oidcClientId string = ''

@description('Include id_token_hint on OIDC logout (false for Login.gov)')
param oidcLogoutIncludeIdTokenHint bool = false

// ---------------------------------------------------------------------------
// OIDC additional request parameters (Login.gov-specific)
// ---------------------------------------------------------------------------
@description('acr_values request parameter')
param oidcAcrValues string = ''

@description('prompt request parameter')
param oidcPrompt string = ''

@description('response_type request parameter')
param oidcResponseType string = ''

// ---------------------------------------------------------------------------
// Azure AD / Entra ID (Internal SSO) — endpoints derived from tenant ID
// ---------------------------------------------------------------------------
@description('Azure AD client ID')
param aadClientId string = ''

@description('Azure AD tenant ID (used to derive endpoints)')
param aadTenantId string = ''

// ---------------------------------------------------------------------------
// JWT (non-secret settings)
// ---------------------------------------------------------------------------
@description('JWT issuer string')
param jwtIssuer string = 'raptor-app'

@description('JWT access token expiration in minutes')
param jwtAccessTokenExpirationMinutes int = 15

@description('JWT refresh token expiration in days')
param jwtRefreshTokenExpirationDays int = 7

// ---------------------------------------------------------------------------
// CORS & Frontend
// ---------------------------------------------------------------------------
@description('CORS allowed origins (comma-separated)')
param corsAllowedOrigins string = ''

@description('Frontend URL for redirects')
param frontendUrl string = ''

// ============================================================================
// Derived values — Azure AD endpoints computed from tenant ID
// ============================================================================
var aadTenantBaseUrl = '${environment().authentication.loginEndpoint}${aadTenantId}'
var aadAuthorizationEndpoint = '${aadTenantBaseUrl}/oauth2/v2.0/authorize'
var aadTokenEndpoint = '${aadTenantBaseUrl}/oauth2/v2.0/token'
var aadUserInfoEndpoint = 'https://graph.microsoft.com/oidc/userinfo'
var aadJwkSetUri = '${aadTenantBaseUrl}/discovery/v2.0/keys'
var aadEndSessionEndpoint = '${aadTenantBaseUrl}/oauth2/v2.0/logout'

// ============================================================================
// App Configuration Store
// ============================================================================
resource configStore 'Microsoft.AppConfiguration/configurationStores@2023-03-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
  }
  properties: {
    disableLocalAuth: false // allow ARM-based key-value writes during deployment
    // Soft delete is only supported on the Standard SKU; Free SKU rejects these properties
    softDeleteRetentionInDays: sku == 'standard' ? softDeleteRetentionInDays : null
    enablePurgeProtection: sku == 'standard' ? enablePurgeProtection : null
  }
}

// ============================================================================
// Key-Value entries — Spring Boot property names as keys
// ============================================================================
// These are loaded automatically by spring-cloud-azure-starter-appconfiguration-config
// using the Spring Cloud Bootstrap mechanism (BootstrapConfiguration in spring.factories).
//
// KEY CONVENTION: Keys use the 'app:' prefix (e.g., app:jwt.issuer).
// The Spring Cloud Azure library's default key-filter (/application/) requires
// forward slashes which are illegal in ARM resource names (% is forbidden in
// App Config keys, so URL-encoding doesn't work either). Using 'app:' avoids
// slashes entirely. The bootstrap config sets selects[0].key-filter=app: and
// the library appends '*' internally, querying 'app:*'. It then strips the
// 'app:' prefix so app:jwt.issuer becomes the Spring property jwt.issuer.
//
// LABEL CONVENTION: Entries are labeled 'azure' to match the active Spring
// profile (SPRING_PROFILES_ACTIVE=azure). The library's default label-filter
// uses active profile names, so no selects override is needed.
// ============================================================================

// Build array of entries, filtering out empty values
var oidcEntries = !empty(oidcAuthorizationEndpoint) ? [
  { key: 'spring.security.oauth2.client.provider.oidc-provider.authorization-uri', value: oidcAuthorizationEndpoint }
  { key: 'spring.security.oauth2.client.provider.oidc-provider.token-uri', value: oidcTokenEndpoint }
  { key: 'spring.security.oauth2.client.provider.oidc-provider.user-info-uri', value: oidcUserInfoEndpoint }
  { key: 'spring.security.oauth2.client.provider.oidc-provider.jwk-set-uri', value: oidcJwkSetUri }
  { key: 'spring.security.oauth2.client.provider.oidc-provider.end-session-endpoint', value: oidcEndSessionEndpoint }
  { key: 'spring.security.oauth2.client.registration.oidc-provider.client-id', value: oidcClientId }
  { key: 'oidc.logout.include-id-token-hint', value: string(oidcLogoutIncludeIdTokenHint) }
] : []

var oidcAdditionalParamEntries = concat(
  !empty(oidcAcrValues) ? [{ key: 'oidc.addl.req.param.acr.values', value: oidcAcrValues }] : [],
  !empty(oidcPrompt) ? [{ key: 'oidc.addl.req.param.prompt', value: oidcPrompt }] : [],
  !empty(oidcResponseType) ? [{ key: 'oidc.addl.req.param.response.type', value: oidcResponseType }] : []
)

var aadEntries = !empty(aadClientId) ? [
  { key: 'spring.security.oauth2.client.provider.azure-ad.authorization-uri', value: aadAuthorizationEndpoint }
  { key: 'spring.security.oauth2.client.provider.azure-ad.token-uri', value: aadTokenEndpoint }
  { key: 'spring.security.oauth2.client.provider.azure-ad.user-info-uri', value: aadUserInfoEndpoint }
  { key: 'spring.security.oauth2.client.provider.azure-ad.jwk-set-uri', value: aadJwkSetUri }
  { key: 'app.azure-ad.end-session-endpoint', value: aadEndSessionEndpoint }
  { key: 'spring.security.oauth2.client.registration.azure-ad.client-id', value: aadClientId }
] : []

var jwtEntries = [
  { key: 'jwt.issuer', value: jwtIssuer }
  { key: 'jwt.access-token-expiration-minutes', value: string(jwtAccessTokenExpirationMinutes) }
  { key: 'jwt.refresh-token-expiration-days', value: string(jwtRefreshTokenExpirationDays) }
]

var corsEntries = !empty(corsAllowedOrigins) ? [
  { key: 'cors.allowed-origins', value: corsAllowedOrigins }
] : []

var frontendEntries = !empty(frontendUrl) ? [
  { key: 'frontend.url', value: frontendUrl }
] : []

var allEntries = concat(oidcEntries, oidcAdditionalParamEntries, aadEntries, jwtEntries, corsEntries, frontendEntries)

// Deploy key-value pairs
// ARM resource name format: {key}${label}
//   - Key uses 'app:' prefix (no slashes to avoid ARM naming issues)
//   - Label 'azure' appended after $ separator
// Example: app:jwt.issuer with label azure → app:jwt.issuer$azure
resource keyValues 'Microsoft.AppConfiguration/configurationStores/keyValues@2023-03-01' = [for (entry, index) in allEntries: {
  parent: configStore
  name: 'app:${entry.key}$azure'
  properties: {
    value: entry.value
  }
}]

// Sentinel key — Spring Cloud Azure App Config monitors this key for changes.
// When its value changes, the library refreshes all configuration properties.
// The value is a hash of all entry values so it changes whenever any config changes.
var sentinelValue = uniqueString(string(allEntries))

resource sentinel 'Microsoft.AppConfiguration/configurationStores/keyValues@2023-03-01' = {
  parent: configStore
  name: 'app:sentinel$azure'
  properties: {
    value: sentinelValue
  }
}

// ============================================================================
// Role Assignment — App Configuration Data Reader for backend identity
// ============================================================================
// Role ID: 516239f1-63e1-4d78-a4de-a74fb236a071 (App Configuration Data Reader)
var appConfigDataReaderRoleId = '516239f1-63e1-4d78-a4de-a74fb236a071'

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(configStore.id, readerPrincipalId, appConfigDataReaderRoleId)
  scope: configStore
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', appConfigDataReaderRoleId)
    principalId: readerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// Outputs
// ============================================================================
output endpoint string = configStore.properties.endpoint
output name string = configStore.name
output id string = configStore.id
