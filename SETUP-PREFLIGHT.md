# Preflight Environment Setup Guide

This document guides you through setting up the `preflight` environment for the image promotion workflow.

## Overview

The `preflight` environment consolidates all environment-specific configuration variables used by notification jobs. This approach:
- ✅ Keeps all 8 environment-specific variables in one place
- ✅ Requires only 1 federated identity credential (instead of 4 separate ones)
- ✅ Separates notification concerns from deployment concerns
- ✅ Simplifies maintenance and updates

## Required Setup Steps

### 1. Create the Preflight Environment

In your GitHub repository (`arif-md/rap-infra`):

1. Go to **Settings** → **Environments**
2. Click **New environment**
3. Name it exactly: `preflight`
4. Click **Configure environment**
5. **Do not** add any protection rules or required reviewers (notification jobs should run automatically)
6. Click **Add variable** and add the following 8 variables:

#### Environment Variables to Add

| Variable Name | Example Value | Description |
|---------------|---------------|-------------|
| `AZURE_ACR_NAME_DEV` | `ngraptordev` | ACR name for dev environment |
| `AZURE_ACR_NAME_TEST` | `ngraptortest` | ACR name for test environment |
| `AZURE_ACR_NAME_TRAIN` | `ngraptortrain` | ACR name for train environment |
| `AZURE_ACR_NAME_PROD` | `ngraptorprod` | ACR name for prod environment |
| `AZURE_RESOURCE_GROUP_DEV` | `rg-raptor-dev` | Resource group for dev |
| `AZURE_RESOURCE_GROUP_TEST` | `rg-raptor-test` | Resource group for test |
| `AZURE_RESOURCE_GROUP_TRAIN` | `rg-raptor-test` | Resource group for train (may share with test) |
| `AZURE_RESOURCE_GROUP_PROD` | `rg-raptor-prod` | Resource group for prod |

### 2. Create Federated Identity Credential in Azure

In Azure Portal or using Azure CLI:

```bash
# Using Azure CLI
az ad app federated-credential create \
  --id <YOUR_APP_OBJECT_ID> \
  --parameters '{
    "name": "rap-infra-preflight",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:arif-md/rap-infra:environment:preflight",
    "audiences": ["api://AzureADTokenExchange"],
    "description": "GitHub Actions - rap-infra preflight environment for notification jobs"
  }'
```

Or in Azure Portal:
1. Go to **Microsoft Entra ID** → **App registrations**
2. Select your application (the one with CLIENT_ID used in GitHub)
3. Go to **Certificates & secrets** → **Federated credentials**
4. Click **Add credential**
5. Choose **GitHub Actions deploying Azure resources**
6. Fill in:
   - **Organization**: `arif-md`
   - **Repository**: `rap-infra`
   - **Entity type**: `Environment`
   - **Environment name**: `preflight`
   - **Name**: `rap-infra-preflight`
7. Click **Add**

### 3. Verify Existing Federated Identities

You should now have exactly **5 federated identity credentials**:

| Name | Subject | Used By |
|------|---------|---------|
| `rap-infra-preflight` | `repo:arif-md/rap-infra:environment:preflight` | Notification jobs |
| `rap-infra-dev` | `repo:arif-md/rap-infra:environment:dev` | Deploy to dev |
| `rap-infra-test` | `repo:arif-md/rap-infra:environment:test` | Deploy to test |
| `rap-infra-train` | `repo:arif-md/rap-infra:environment:train` | Deploy to train |
| `rap-infra-prod` | `repo:arif-md/rap-infra:environment:prod` | Deploy to prod |

### 4. Remove Old Repository Variables (Optional)

If you previously had repository-level variables for ACR names and resource groups, you can now safely remove them:

Go to **Settings** → **Secrets and variables** → **Actions** → **Variables** tab

You can remove (if they exist):
- `AZURE_ACR_NAME`
- `AZURE_ACR_NAME_DEV`
- `AZURE_ACR_NAME_TEST`
- `AZURE_ACR_NAME_TRAIN`
- `AZURE_ACR_NAME_PROD`
- `AZURE_RESOURCE_GROUP`
- `AZURE_RESOURCE_GROUP_DEV`
- `AZURE_RESOURCE_GROUP_TEST`
- `AZURE_RESOURCE_GROUP_TRAIN`
- `AZURE_RESOURCE_GROUP_PROD`

Keep only:
- `DEFAULT_GITHUB_ENV` (if you want to override the default `dev` base environment)

## Testing

After setup, trigger a promotion workflow and verify:

1. The `prepare-and-notify-test` job should:
   - ✅ Authenticate using the preflight federated identity
   - ✅ Access the environment variables successfully
   - ✅ Query the correct ACR and resource group
   - ✅ Generate release notes with commit changelog
   - ✅ Send email notification

2. Check the job logs for:
   ```
   Using ACR: ngraptortest
   Using RG: rg-raptor-test
   ```

## Troubleshooting

### "No matching federated identity record found"

**Cause**: The preflight federated identity credential is not configured correctly in Azure.

**Solution**:
1. Verify the subject exactly matches: `repo:arif-md/rap-infra:environment:preflight`
2. Check that you're using the correct Application (Client) ID in GitHub secrets
3. Ensure the credential is added to the same App Registration used by `AZURE_CLIENT_ID`

### "Required variable not found"

**Cause**: One of the 8 required variables is missing from the preflight environment.

**Solution**:
1. Go to **Settings** → **Environments** → **preflight**
2. Verify all 8 variables are configured
3. Check for typos in variable names (they are case-sensitive)

### ACR or resource group not found

**Cause**: The variable values don't match actual Azure resource names.

**Solution**:
1. Verify ACR names and resource groups exist in Azure
2. Check the values in the preflight environment variables
3. Update variables to match actual resource names

## Migration from Repository Variables

If you previously used repository-level variables:

1. **Copy values** from repository variables to preflight environment variables
2. **Test** a promotion workflow to ensure it works
3. **Remove** old repository variables only after successful test
4. **No workflow changes needed** - the fallback logic still works

The workflow tries environment-specific variables first (from preflight), then falls back to repository variables if needed.
