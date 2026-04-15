// ============================================================================
// HTTP Route Config — path-based routing
// ============================================================================
// Bicep ONLY creates the route config with routing rules.
// Everything DNS and custom domain related is handled by scripts:
//   - Preprovision: ensure-dns-zone.ps1 (creates DNS zone, survives azd down)
//   - Post-provision: bind-custom-domain-tls.ps1 (DNS records, domain binding,
//     TLS certificate creation, and SniEnabled binding)
//
// This clean separation avoids:
//   - InvalidCustomHostNameValidation (ARM validates DNS during deployment)
//   - DNS propagation timing issues after azd down/up
//   - Deployment stack deleting DNS records on azd down
// ============================================================================

@description('Container Apps Environment name')
param containerAppsEnvironmentName string

@description('Frontend container app name')
param frontendAppName string

@description('Backend container app name')
param backendAppName string

@description('Processes container app name')
param processesAppName string

// Reference existing CAE
resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerAppsEnvironmentName
}

// ============================================================================
// Route rules (evaluated in order):
//   /api/*        → backend (keeps /api prefix)
//   /auth/*       → backend (Spring Security auth endpoints)
//   /oauth2/*     → backend (Spring Security OAuth2 flow)
//   /login/*      → backend (OIDC callback /login/oauth2/code/*)
//   /swagger-ui/* → backend (Swagger docs)
//   /v3/*         → backend (OpenAPI spec)
//   /actuator/*   → backend (Spring Boot health/info)
//   /processes/*  → processes (jBPM, rewrite prefix to /)
//   /*            → frontend (catch-all, must be last)
// ============================================================================
resource httpRouteConfig 'Microsoft.App/managedEnvironments/httpRouteConfigs@2025-07-01' = {
  parent: containerAppsEnvironment
  name: 'raptorrouting'
  properties: {
    rules: [
      {
        description: 'Route API and auth calls to backend'
        routes: [
          { match: { pathSeparatedPrefix: '/api' }, action: { prefixRewrite: '/api' } }
          { match: { pathSeparatedPrefix: '/auth' }, action: { prefixRewrite: '/auth' } }
          { match: { pathSeparatedPrefix: '/oauth2' }, action: { prefixRewrite: '/oauth2' } }
          { match: { pathSeparatedPrefix: '/login' }, action: { prefixRewrite: '/login' } }
          { match: { pathSeparatedPrefix: '/swagger-ui' }, action: { prefixRewrite: '/swagger-ui' } }
          { match: { pathSeparatedPrefix: '/v3' }, action: { prefixRewrite: '/v3' } }
          { match: { pathSeparatedPrefix: '/actuator' }, action: { prefixRewrite: '/actuator' } }
        ]
        targets: [
          { containerApp: backendAppName }
        ]
      }
      {
        description: 'Route process calls to jBPM'
        routes: [
          { match: { pathSeparatedPrefix: '/processes' }, action: { prefixRewrite: '/' } }
        ]
        targets: [
          { containerApp: processesAppName }
        ]
      }
      {
        description: 'Catch-all routes to frontend'
        routes: [
          { match: { prefix: '/' } }
        ]
        targets: [
          { containerApp: frontendAppName }
        ]
      }
    ]
  }
}

output routeConfigName string = httpRouteConfig.name
output routeConfigFqdn string = httpRouteConfig.properties.fqdn
