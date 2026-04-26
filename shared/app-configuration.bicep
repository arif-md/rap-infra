// ============================================================================
// Azure App Configuration — Centralized Configuration Store
// ============================================================================
// Stores non-secret operational config (JWT settings, CORS, frontend URL)
// and Key Vault references for secrets (jwt.secret, azure-ad client-secret).
//
// OIDC/AAD provider configuration is hardcoded in Spring Boot profile-specific
// application properties (application-dev.properties, application-test.properties,
// etc.) — not stored here. Those values are environment constants that don't
// need runtime refresh.
//
// Spring Boot reads these entries at startup via:
//   spring-cloud-azure-starter-appconfiguration-config (bootstrap phase)
// ============================================================================

@description('App Configuration store name')
param name string

@description('Azure region')
param location string = resourceGroup().location

@description('Resource tags')
param tags object = {}

@description('App Configuration SKU')
@allowed(['free', 'developer', 'standard', 'premium'])
param sku string = 'developer'

@description('Soft-delete retention in days (1-7). Lower = faster name reuse after azd down. Only applies to Standard/Premium SKUs.')
@minValue(1)
@maxValue(7)
param softDeleteRetentionInDays int = 1

@description('Enable purge protection (prevents permanent deletion during retention period). Only applies to Standard/Premium SKUs.')
param enablePurgeProtection bool = false

@description('Enable private endpoint (requires Developer SKU or higher and VNet integration)')
param enablePrivateEndpoint bool = false

@description('Subnet resource ID for the private endpoint (required when enablePrivateEndpoint is true)')
param privateEndpointSubnetId string = ''

@description('Private DNS zone resource ID for privatelink.azconfig.io (required when enablePrivateEndpoint is true)')
param privateDnsZoneId string = ''

@description('Principal ID to grant App Configuration Data Reader role (backend managed identity)')
param readerPrincipalId string

@description('Label applied to all key-value entries. Must match the Spring Boot profile name (e.g. dev, test, train, prod). bootstrap-{profile}.properties sets label-filter to this value.')
param environmentLabel string

// ---------------------------------------------------------------------------
// JWT (non-secret settings — safe for App Config, support runtime refresh)
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

// ---------------------------------------------------------------------------
// Key Vault — for Key Vault reference entries (secrets resolved by Spring library)
// ---------------------------------------------------------------------------
@description('Key Vault endpoint URI (e.g. https://kv-name.vault.azure.net/). Required for KV reference entries.')
param keyVaultEndpoint string = ''

@description('Enable Azure AD SSO — when true, adds a KV reference entry for the AAD client secret.')
param enableAadSso bool = true

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
    // Keep public network access ENABLED even when a private endpoint exists.
    // Reason: the ARM deployment engine writes key-value entries from Azure's
    // public infrastructure — disabling public access blocks those writes and
    // causes "Forbidden: Access to the requested resource is forbidden" errors.
    // Security is provided by RBAC (Managed Identity) not by network firewall;
    // the private endpoint ensures containers inside the VNet use private routing.
    publicNetworkAccess: 'Enabled'
    // Soft delete and purge protection are only supported on Standard/Premium SKUs
    softDeleteRetentionInDays: (sku == 'standard' || sku == 'premium') ? softDeleteRetentionInDays : null
    enablePurgeProtection: (sku == 'standard' || sku == 'premium') ? enablePurgeProtection : null
  }
}

// ============================================================================
// Key-Value entries — operational config only (no OIDC/AAD — those are in
// Spring Boot profile-specific properties files)
// ============================================================================
// KEY CONVENTION: 'app:' prefix avoids slashes in ARM resource names.
//   The library queries 'app:*' and strips the prefix, so
//   'app:jwt.issuer' → Spring property 'jwt.issuer'.
// LABEL CONVENTION: environmentLabel (e.g. 'dev') — must match the value in
//   bootstrap-{profile}.properties label-filter and the Container App's
//   SPRING_PROFILES_ACTIVE env var.
// ============================================================================

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

var allEntries = concat(jwtEntries, corsEntries, frontendEntries)

// Plain key-value pairs (non-secret operational config)
// ARM resource name: app:{key}${environmentLabel}
resource keyValues 'Microsoft.AppConfiguration/configurationStores/keyValues@2023-03-01' = [for (entry, index) in allEntries: {
  parent: configStore
  name: 'app:${entry.key}$${environmentLabel}'
  properties: {
    value: entry.value
  }
}]

// Sentinel key — Spring Cloud Azure App Config monitors this key every 30 seconds.
// When its value changes (because allEntries changed), the library refreshes all
// properties without a container restart.
var sentinelValue = uniqueString(string(allEntries))

resource sentinel 'Microsoft.AppConfiguration/configurationStores/keyValues@2023-03-01' = {
  parent: configStore
  name: 'app:sentinel$${environmentLabel}'
  properties: {
    value: sentinelValue
  }
}

// ============================================================================
// Key Vault reference entries — secrets resolved at Spring Boot startup
// ============================================================================
// These entries use content-type 'application/vnd.microsoft.appconfig.keyvaultref+json'
// which tells the Spring Cloud Azure App Config library to call Key Vault via
// the managed identity to retrieve the actual secret value. The resolved value
// is exposed as a Spring property — no env var, no Container App secretRef needed.
//
// Requirements: backend managed identity must have Key Vault Secrets User RBAC
// role OR a Key Vault access policy with 'get' permission (set by ensure-identities.sh).
// ============================================================================

// jwt.secret — required for JWT signing/verification (JwtTokenUtil @Value("${jwt.secret}"))
resource kvRefJwtSecret 'Microsoft.AppConfiguration/configurationStores/keyValues@2023-03-01' = if (!empty(keyVaultEndpoint)) {
  parent: configStore
  name: 'app:jwt.secret$${environmentLabel}'
  properties: {
    value: '{"uri":"${keyVaultEndpoint}secrets/jwt-secret"}'
    contentType: 'application/vnd.microsoft.appconfig.keyvaultref+json;charset=utf-8'
  }
}

// spring.security.oauth2.client.registration.azure-ad.client-secret
// — required for Azure AD authorization_code flow
resource kvRefAadClientSecret 'Microsoft.AppConfiguration/configurationStores/keyValues@2023-03-01' = if (!empty(keyVaultEndpoint) && enableAadSso) {
  parent: configStore
  name: 'app:spring.security.oauth2.client.registration.azure-ad.client-secret$${environmentLabel}'
  properties: {
    value: '{"uri":"${keyVaultEndpoint}secrets/aad-client-secret"}'
    contentType: 'application/vnd.microsoft.appconfig.keyvaultref+json;charset=utf-8'
  }
}

// ============================================================================
// Private Endpoint (optional — only when enablePrivateEndpoint is true)
// ============================================================================
// Connects the App Config store to the private-endpoints subnet so that all
// containers within the VNet resolve <name>.azconfig.io to a private IP.
// One private endpoint is shared by all containers (backend, processes, replicas).
// ============================================================================
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = if (enablePrivateEndpoint) {
  name: 'pe-${name}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'appcs-connection'
        properties: {
          privateLinkServiceId: configStore.id
          groupIds: [
            'configurationStores'
          ]
        }
      }
    ]
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = if (enablePrivateEndpoint) {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-azconfig-io'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
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
output privateEndpointId string = enablePrivateEndpoint ? privateEndpoint.id : ''
