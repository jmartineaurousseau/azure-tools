param(
    [switch]$WhatIf
)

# Read Configuration
$configPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $configPath)) {
    Write-Error "Configuration file not found at $configPath"
    exit 1
}
$config = Get-Content $configPath | ConvertFrom-Json

# Set Subscription
if ($config.subscriptionId -and $config.subscriptionId -ne "00000000-0000-0000-0000-000000000000") {
    Write-Host "Setting subscription context to $($config.subscriptionId)..."
    az account set --subscription $config.subscriptionId
}

$params = @(
    "resourceGroupName=$($config.resourceGroupName)",
    "location=$($config.location)",
    "functionAppName=$($config.functionAppName)",
    "storageAccountName=$($config.storageAccountName)",
    "deployAppInsights=$($config.deployAppInsights)"
)

if ($WhatIf) {
    Write-Host "Running What-If deployment..."
    az deployment sub create `
        --name "azure-tools-deploy-$(Get-Date -Format 'yyyyMMddHHmm')" `
        --location $config.location `
        --template-file "bicep/main.bicep" `
        --parameters $params `
        --what-if
}
else {
    Write-Host "Starting deployment..."
    $deploymentOutput = az deployment sub create `
        --name "azure-tools-deploy-$(Get-Date -Format 'yyyyMMddHHmm')" `
        --location $config.location `
        --template-file "bicep/main.bicep" `
        --parameters $params `
        --output json | ConvertFrom-Json

    $appName = $deploymentOutput.properties.outputs.functionAppName.value
    Write-Host "Deployed Function App: $appName"

    if ($appName) {
        Write-Host "Publishing Function App code..."
        # Navigate to root to run func command, assuming deploy.ps1 is in bicep/
        Push-Location "$PSScriptRoot/.."
        func azure functionapp publish $appName
        Pop-Location
    }
    else {
        Write-Host "Error: functionAppName output not found."
    }
}
