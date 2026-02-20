param(
    [switch]$WhatIf
)

# Read Configuration
$configPath = Join-Path $PSScriptRoot "bicep-config.json"
if (-not (Test-Path $configPath)) {
    Write-Error "Configuration file not found at $configPath"
    exit 1
}
$config = Get-Content $configPath | ConvertFrom-Json


# Check for Azure Functions Core Tools
if (-not (Get-Command func -ErrorAction SilentlyContinue)) {
    Write-Warning "Azure Functions Core Tools not found. Attempting to install via Winget..."
    winget install Microsoft.Azure.FunctionsCoreTools --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to install Azure Functions Core Tools via Winget. Please install manually."
        exit 1
    }
    # Refresh path for current session
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# Set Subscription
if ($config.subscriptionId -and $config.subscriptionId -ne "00000000-0000-0000-0000-000000000000") {
    Write-Host "Setting subscription context to $($config.subscriptionId)..."
    az account set --subscription $config.subscriptionId
}

$params = @(
    "resourceGroupName=$($config.resourceGroupName)",
    "location=$($config.location)",
    "functionAppName=$($config.functionAppName)",
    "storageAccountName=$($config.storageAccountName)"
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
