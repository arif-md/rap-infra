# Deprecated Workflows Removed

**Date**: October 25, 2025

## Removed Files

The following deprecated generic workflows have been removed to prevent duplicate workflow runs:

1. ✅ **`infra-azd.yaml`** (deprecated generic deployment workflow)
2. ✅ **`promote-image.yaml`** (deprecated generic promotion workflow)

## Reason for Removal

These workflows were triggering **duplicate runs** alongside the new service-specific workflows:
- When a `frontend-image-pushed` event occurred, BOTH `infra-azd.yaml` AND `deploy-frontend.yaml` would run
- When a `frontend-image-promote` event occurred, BOTH `promote-image.yaml` AND `promote-frontend.yaml` would run

## Current Active Workflows

Service-specific workflows (kept):

### Deployment Workflows
- ✅ **`deploy-frontend.yaml`** - Deploys frontend service
- ✅ **`deploy-backend.yaml`** - Deploys backend service

### Promotion Workflows
- ✅ **`promote-frontend.yaml`** - Promotes frontend image across environments
- ✅ **`promote-backend.yaml`** - Promotes backend image across environments

## Benefits of Removal

✅ **No more duplicate runs** - Each event triggers only one workflow  
✅ **Cleaner workflow history** - No confusion about which workflow ran  
✅ **Faster CI/CD** - Half the number of workflow runs  
✅ **Clear ownership** - Each service has dedicated workflows  
✅ **Better maintainability** - Service-specific logic in dedicated files  

## Trigger Mapping

| Repository Event | Triggers Workflow |
|------------------|-------------------|
| `frontend-image-pushed` | `deploy-frontend.yaml` only |
| `backend-image-pushed` | `deploy-backend.yaml` only |
| `frontend-image-promote` | `promote-frontend.yaml` only |
| `backend-image-promote` | `promote-backend.yaml` only |
| Path changes: `app/frontend-angular.bicep` | `deploy-frontend.yaml` |
| Path changes: `app/backend-azure-functions.bicep` | `deploy-backend.yaml` |
| Path changes: `modules/**`, `shared/**` | Both deployment workflows |

## Migration Complete

No action needed - the service-specific workflows are already in use and working correctly. The deprecated workflows were kept temporarily with deprecation notices, but are now fully removed.

## References

- **[WORKFLOWS.md](../../docs/WORKFLOWS.md)** - Complete guide to service-specific workflows
- **[ARCHITECTURE-STRATEGIES.md](../../docs/ARCHITECTURE-STRATEGIES.md)** - Multi-service architecture patterns
