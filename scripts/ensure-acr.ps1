Param(
  [string]$AcrName = $env:AZURE_ACR_NAME,
  [string]$ResourceGroup = $env:AZURE_RESOURCE_GROUP,
  [string]$Location = $env:AZURE_LOCATION,
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
if (-not $Location) { $Location = Get-AzdValue 'AZURE_LOCATION' }

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
if (-not $Location) {
  # Fallback to a commonly available region if RG doesn't exist yet
  $Location = 'eastus2'
}

# Ensure resource group exists (do not create it)
Write-Host "[ensure-acr] Using RG='$ResourceGroup' Location='$Location' ACR='$AcrName'"
$rgExists = az group show -n $ResourceGroup -o none 2>$null
if ($LASTEXITCODE -ne 0) {
  throw "Resource group '$ResourceGroup' was not found. Set AZURE_RESOURCE_GROUP to an existing RG (azd env set AZURE_RESOURCE_GROUP <name>) or pre-create '$ResourceGroup'."
}

# If location still unknown, read it from the existing RG
if (-not $Location) {
  $Location = (az group show -n $ResourceGroup --query location -o tsv 2>$null)
}

$exists = $false
az acr show -n $AcrName -g $ResourceGroup -o none 2>$null
$exists = ($LASTEXITCODE -eq 0)
if (-not $exists) {
  $check = az acr check-name -n $AcrName -o json | ConvertFrom-Json
  if (-not $check.nameAvailable -and $check.reason -ne 'AlreadyExists') {
    throw "ACR name '$AcrName' is not valid: $($check.message)"
  }
  if (-not $check.nameAvailable -and $check.reason -eq 'AlreadyExists') {
    Write-Host "[ensure-acr] ACR name '$AcrName' exists globally but not in RG '$ResourceGroup'. Choose a unique name or use an existing registry in this RG."
    throw "ACR name already taken globally: $AcrName"
  }
  Write-Host "[ensure-acr] Creating ACR '$AcrName' in RG '$ResourceGroup'..."
  az acr create -n $AcrName -g $ResourceGroup -l $Location --sku Standard --admin-enabled false --only-show-errors 1>$null
} else {
  Write-Host "[ensure-acr] ACR '$AcrName' already exists in RG '$ResourceGroup'."
}

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
