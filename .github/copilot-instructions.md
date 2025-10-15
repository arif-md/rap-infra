# RAP Infrastructure Project Guide

<!-- 
MAINTENANCE GUIDE:
- Last updated: October 15, 2025
- Update triggers: When you modify architecture, add modules, change workflows, or introduce new patterns
- Update method: Ask Copilot "Update copilot-instructions.md based on recent changes" or edit manually
- Full refresh: Quarterly or after major refactoring - ask "Re-analyze and update copilot-instructions.md"

Key sections to update when:
- Adding/removing Azure resources → "Key Components" and "File Patterns"
- Changing deployment process → "Development Workflows" and "Key Commands"
- New scripts or automation → "Scripts" and "Integration Points"
- Environment variables → "Environment Configuration" and "Parameter Files"
- CI/CD changes → "Image Promotion Workflow" and "Integration Points"
-->

## Architecture Overview

This is a **RAP (Raptor) prototype infrastructure** repository using Azure Developer CLI (azd) for deploying containerized Angular frontend and Azure Functions backend to Azure Container Apps.

### Key Components
- **Frontend**: Angular app deployed to Container Apps (`app/frontend-angular.bicep`)
- **Backend**: Azure Functions (placeholder in `app/backend-azure-functions.bicep`)
- **Infrastructure**: Bicep templates with Azure Verified Modules (AVM)
- **CI/CD**: Image promotion pipeline (dev → test → prod) with digest-based deployments

### Project Structure
```
main.bicep              # Entry point, references AVM modules
main.parameters.json    # Environment variable substitutions via azd
azure.yaml              # azd configuration with deployment stacks
app/                    # Application-specific Bicep modules
modules/                # Reusable infrastructure components
scripts/                # PowerShell/bash hooks for ACR provisioning
shared/                 # Shared infrastructure patterns (registry, monitoring)
```

## Core Patterns

### Environment Configuration
- Uses `azd env` for environment-specific values: `AZURE_ENV_NAME`, `AZURE_ACR_NAME`, `AZURE_RESOURCE_GROUP`
- Parameters file uses `${VAR}` substitution from azd environment
- Default ACR naming: `${environmentName}rapacr` (cleaned of special chars)

### ACR Integration
- **External ACR assumption**: ACR exists outside main deployment stack
- `scripts/ensure-acr.ps1` pre-provision hook ensures ACR exists before deployment
- Role assignments handled via `modules/acrPullRoleAssignment.bicep`
- Use `skipAcrPullRoleAssignment=true` for local dev without RBAC permissions

### Container Apps Pattern
- All apps use user-assigned managed identities for ACR access
- Template in `modules/containerApp.bicep` with standardized CPU/memory options
- Environment variables passed as arrays: `[{name: 'VAR', value: 'value'}]`
- Ingress configured with sticky sessions support

### Deployment Stacks
- Enabled in `azure.yaml` with `actionOnUnmanage: resources: delete, resourceGroups: detach`
- Preserves resource groups on `azd down` while cleaning managed resources
- Uses alpha deployment stacks feature: requires `azd config set alpha.deployment.stacks on`

## Development Workflows

### Initial Setup
```powershell
azd env new dev
azd env set AZURE_SUBSCRIPTION_ID <subscription-id>
azd env set AZURE_ENV_NAME dev
azd env set AZURE_RESOURCE_GROUP rg-raptor-dev
azd env set AZURE_ACR_NAME ngraptordev
```

### Local Development
- Use `azd auth login` or service principal auth matching CI
- Check `az configure --list-defaults` and clear unwanted defaults with `az configure --defaults group=`
- ACR commands should be RG-scoped: `az acr show -n <name> -g <rg>`

### Image Promotion Workflow
- Built images tagged with digest for immutable deployment
- Promotion imports manifests between ACRs: `az acr import --source <digest>`
- Release notes generated from OCI labels: `org.opencontainers.image.revision`
- Container App tagged with `raptor.lastDigest` and `raptor.lastCommit` for durability

## File Patterns

### Bicep Conventions
- Use `abbreviations.json` for consistent resource naming
- Generate unique suffix with `uniqueString(subscription().id, resourceGroup().id, location)`
- Prefer Azure Verified Modules: `br/public:avm/ptn/azd/monitoring:0.1.0`
- External dependencies referenced by name, not resource ID (e.g., ACR)

### Parameter Files
- Environment substitution: `"value": "${AZURE_ENV_NAME}"`
- Boolean defaults: `"value": "${SKIP_ACR_PULL_ROLE_ASSIGNMENT=true}"`
- Complex objects for service definitions with settings arrays

### Scripts
- PowerShell/bash cross-platform with `.ps1` and `.sh` variants
- Error handling: `$ErrorActionPreference = 'Stop'` in PowerShell
- azd integration: Use `azd env get-value` to read environment values
- Validation: Check resource group existence before creating resources

## Key Commands

```powershell
# Deploy
azd up

# Get frontend URL
azd env get-value frontendFqdn

# Clean up (keeps RG)
azd down

# Check auth context
az account show --output table
azd env list
```

## Integration Points

- **GitHub Actions**: Repository dispatch events (`frontend-image-pushed`, `frontend-image-promote`)
- **Email notifications**: SMTP integration in promotion workflow with HTML release notes
- **Cross-repo**: Frontend repo triggers infra deployment via PAT tokens
- **Monitoring**: Application Insights integration via AVM monitoring pattern