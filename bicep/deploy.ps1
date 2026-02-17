param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName = "rg-azure-tools",
    [string]$Location = "canadacentral",
    [switch]$WhatIf
)

if ($SubscriptionId) {
    Write-Host "Setting subscription context to $SubscriptionId..."
    az account set --subscription $SubscriptionId
}

$params = @{
    resourceGroupName = $ResourceGroupName
    location          = $Location
}

if ($WhatIf) {
    Write-Host "Running What-If deployment..."
    az deployment sub create --name "azure-tools-deploy-$(Get-Date -Format 'yyyyMMddHHmm')" `
        --location $Location `
        --template-file "bicep/main.bicep" `
        --parameters $params `
        --what-if
}
else {
    Write-Host "Starting deployment..."
    $deploymentOutput = az deployment sub create `
        --name "azure-tools-deploy-$(Get-Date -Format 'yyyyMMddHHmm')" `
        --location $Location `
        --template-file "bicep/main.bicep" `
        --parameters $params `
        --output json | ConvertFrom-Json

    $appName = $deploymentOutput.properties.outputs.functionAppName.value
    Write-Host "Deployed Function App: $appName"

    if ($appName) {
        Write-Host "Publishing Function App code..."
        # Publish from root directory where function_app.py resides
        func azure functionapp publish $appName
    }
    else {
        Write-Host "Error: efficient functionAppName output not found."
    }
}
