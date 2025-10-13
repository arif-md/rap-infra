Param(
  [string]$AcrName = $env:AZURE_ACR_NAME,
  [string]$ResourceGroup = $env:AZURE_RESOURCE_GROUP,
  [string]$Location,
  [string]$EnvName = $env:AZURE_ENV_NAME
)

$ErrorActionPreference = 'Stop'

function Get-AzdValue([string]$key) {
  $val = & azd env get-value $key 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  if ($null -ne $val -and ($val.TrimStart()).StartsWith('ERROR:')) { return $null }
  return $val
}

if (-not $EnvName) { $EnvName = Get-AzdValue 'AZURE_ENV_NAME' }
if (-not $AcrName)  { $AcrName  = Get-AzdValue 'AZURE_ACR_NAME' }
if (-not $ResourceGroup) { $ResourceGroup = Get-AzdValue 'AZURE_RESOURCE_GROUP' }

if (-not $AcrName) {
  if (-not $EnvName) {
    throw "AZURE_ACR_NAME not set and AZURE_ENV_NAME unavailable. Select an azd environment or set AZURE_ACR_NAME via 'azd env set AZURE_ACR_NAME <acrName>'."
  }
  # derive a stable default from env name
  $AcrName = ("$EnvName-rap-acr").ToLower() -replace "[^a-z0-9]",""
  if ($AcrName.Length -gt 50) { $AcrName = $AcrName.Substring(0,50) }
  azd env set AZURE_ACR_NAME $AcrName | Out-Null
}

if (-not $ResourceGroup) {
  if ($EnvName) {
    $ResourceGroup = ("rg-raptor-$EnvName").ToLower()
    azd env set AZURE_RESOURCE_GROUP $ResourceGroup | Out-Null
  } else {
    throw "AZURE_RESOURCE_GROUP not set and AZURE_ENV_NAME unavailable. Ensure your azd environment is selected and initialized."
  }
}

if (-not $Location) {
  $Location = (az group show -n $ResourceGroup --query location -o tsv 2>$null)
}
if (-not $Location) { throw "Could not resolve location for resource group '$ResourceGroup'." }

# Ensure resource group exists (do not create it)
Write-Host "[ensure-acr] Using RG='$ResourceGroup' Location='$Location' ACR='$AcrName'"
az group show -n $ResourceGroup -o none 2>$null
if ($LASTEXITCODE -ne 0) {
  throw "Resource group '$ResourceGroup' was not found. Set AZURE_RESOURCE_GROUP to an existing RG (azd env set AZURE_RESOURCE_GROUP <name>) or pre-create '$ResourceGroup'."
}

# If location still unknown, read it from the existing RG
if (-not $Location) {
  $Location = (az group show -n $ResourceGroup --query location -o tsv 2>$null)
}

# If user pre-provided the ACR resource group, skip discovery/creation
<#
  Unify behavior for GitHub and local: perform subscription-wide discovery first.
  If ACR exists, set AZURE_ACR_RESOURCE_GROUP accordingly.
  If not, validate name and create in preferred RG: AZURE_ACR_RESOURCE_GROUP if provided, else AZURE_RESOURCE_GROUP.
#>
$preferredAcrRg = $env:AZURE_ACR_RESOURCE_GROUP

# Permissions preflight: verify required roles on target resource group for ACR create and role assignment
$subId = az account show --query id -o tsv 2>$null
$assignee = az account show --query user.name -o tsv 2>$null
$targetRg = if ($preferredAcrRg) { $preferredAcrRg } else { $ResourceGroup }

az group show -n $targetRg -o none 2>$null
if ($LASTEXITCODE -ne 0) {
  throw "[preflight] Target ACR resource group '$targetRg' not found. Set AZURE_ACR_RESOURCE_GROUP to an existing RG or create it."
}

if ($subId -and $assignee) {
  $roles = az role assignment list --assignee $assignee --scope "/subscriptions/$subId/resourceGroups/$targetRg" --include-inherited --query "[].roleDefinitionName" -o tsv 2>$null
  if ($LASTEXITCODE -eq 0 -and $roles) {
    Write-Host "[preflight] Roles for principal '$assignee' at RG '$targetRg': $($roles -join ', ')"
    if (-not ($roles -match 'Owner' -or $roles -match 'Contributor')) {
      throw "[preflight][ERROR] Missing Contributor or Owner on resource group '$targetRg'. This is required to create or update ACR and related resources. [HINT] Grant 'Contributor' (minimum) or 'Owner' at: /subscriptions/$subId/resourceGroups/$targetRg"
    }
    if (-not ($roles -match 'Owner' -or $roles -match 'User Access Administrator')) {
      throw "[preflight][ERROR] Missing permission to create role assignments in RG '$targetRg'. [DETAIL] Assigning AcrPull requires 'Owner' or 'User Access Administrator' on the ACR's resource group. [HINT] Grant 'Owner' or 'User Access Administrator' at: /subscriptions/$subId/resourceGroups/$targetRg"
    }
  } else {
    Write-Warning "[preflight] Could not read role assignments at scope '/subscriptions/$subId/resourceGroups/$targetRg'. Ensure your principal can read role assignments. Continuing, but operations may fail."
  }
} else {
  Write-Warning "[preflight] Unable to resolve subscription or principal for role checks; skipping permission preflight."
}

# Try to find the ACR anywhere in the current subscription (not restricted to RG)
$acrInfoJson = az acr show -n $AcrName -o json 2>$null
if ($LASTEXITCODE -eq 0 -and $acrInfoJson) {
  $acrInfo = $acrInfoJson | ConvertFrom-Json
  $acrRg = $acrInfo.resourceGroup
  if (-not $acrRg -and $acrInfo.id) {
    if ($acrInfo.id -match "/resourceGroups/([^/]+)/providers/") { $acrRg = $Matches[1] }
  }
  Write-Host "[ensure-acr] ACR '$AcrName' already exists in subscription in RG '${acrRg}' (using existing registry)."
  if ($acrRg) { azd env set AZURE_ACR_RESOURCE_GROUP $acrRg | Out-Null }
  # Re-check role assignment permission on actual ACR RG
  if ($subId -and $assignee -and $acrRg) {
    $rolesAcr = az role assignment list --assignee $assignee --scope "/subscriptions/$subId/resourceGroups/$acrRg" --include-inherited --query "[].roleDefinitionName" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $rolesAcr) {
      Write-Host "[preflight] Roles for principal '$assignee' at ACR RG '$acrRg': $($rolesAcr -join ', ')"
      if (-not ($rolesAcr -match 'Owner' -or $rolesAcr -match 'User Access Administrator')) {
        throw "[preflight][ERROR] Missing permission to create role assignments in ACR RG '$acrRg'. [DETAIL] Assigning AcrPull requires 'Owner' or 'User Access Administrator' on the ACR's resource group. [HINT] Grant 'Owner' or 'User Access Administrator' at: /subscriptions/$subId/resourceGroups/$acrRg"
      }
    } else {
      Write-Warning "[preflight] Could not read role assignments at scope '/subscriptions/$subId/resourceGroups/$acrRg'. Ensure your principal can read role assignments. Continuing, but operations may fail."
    }
  }
} else {
  # Not found in current subscription, check global name availability
  $check = az acr check-name -n $AcrName -o json | ConvertFrom-Json
  if ($null -eq $check) { throw "Failed to validate ACR name '$AcrName'" }
  $targetRg = if ($preferredAcrRg) { $preferredAcrRg } else { $ResourceGroup }
  if (-not $Location) {
    $Location = (az group show -n $targetRg --query location -o tsv 2>$null)
  }
  if ($check.nameAvailable -eq $true) {
    Write-Host "[ensure-acr] Creating ACR '$AcrName' in RG '$targetRg'..."
    az acr create -n $AcrName -g $targetRg -l $Location --sku Standard --admin-enabled false --only-show-errors 1>$null
    azd env set AZURE_ACR_RESOURCE_GROUP $targetRg | Out-Null
  } else {
    if ($check.reason -eq 'AlreadyExists') {
      $sub = az account show --query id -o tsv 2>$null
      $subName = az account show --query name -o tsv 2>$null
      throw "[ensure-acr] ACR name '$AcrName' exists, but is not accessible in subscription '$subName' ($sub) with current permissions. Ensure your principal has Microsoft.ContainerRegistry/registries/read on the registry, or switch to the subscription where it exists. Message: $($check.message)"
    } else {
      throw "[ensure-acr] ACR name '$AcrName' is not valid/available: $($check.message)"
    }
  }
}

:ResolveImage

# Resolve the service image if not already set, preferring ACR digest for this environment
$currentImage = Get-AzdValue 'SERVICE_FRONTEND_IMAGE_NAME'
$acrDomain = "$AcrName.azurecr.io"
if (-not $currentImage -or -not $currentImage.StartsWith($acrDomain, [System.StringComparison]::OrdinalIgnoreCase)) {
  $repo = "raptor/frontend-$EnvName"
  Write-Host "[ensure-acr] Attempting to resolve latest image from ACR: $acrDomain/$repo"
  $digest = az acr repository show-manifests -n $AcrName --repository $repo --orderby time_desc --top 1 --query "[0].digest" -o tsv 2>$null
  if ($LASTEXITCODE -eq 0 -and $digest) {
    $image = "$acrDomain/$repo@$digest"
    Write-Host "[ensure-acr] Resolved ACR image: $image"
    azd env set SERVICE_FRONTEND_IMAGE_NAME $image | Out-Null
    azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT false | Out-Null
  } else {
    $fallback = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
    Write-Host "[ensure-acr] No image found in ACR repo '$repo'. Using fallback public image: $fallback"
    azd env set SERVICE_FRONTEND_IMAGE_NAME $fallback | Out-Null
    azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT true | Out-Null
  }
} else {
  Write-Host "[ensure-acr] SERVICE_FRONTEND_IMAGE_NAME already set to ACR image; leaving as-is."
}
