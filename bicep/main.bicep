targetScope = 'subscription'

@description('The name of the resource group to deploy to')
param resourceGroupName string = 'rg-azure-tools'

@description('The location to deploy resources to')
param location string = 'eastus'

@description('The name of the function app')
param functionAppName string = 'func-azure-tools-${uniqueString(subscription().id, resourceGroupName)}'

@description('The name of the storage account')
param storageAccountName string = 'staztools${uniqueString(subscription().id, resourceGroupName)}'

// Resource Group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
}

// Storage Account Module
module storage 'br/public:avm/res/storage/storage-account:0.9.1' = {
  scope: rg
  name: 'storageDeployment'
  params: {
    name: storageAccountName
    location: location
    skuName: 'Standard_LRS'
    allowBlobPublicAccess: false
  }
}

// App Service Plan Module
module appServicePlan 'br/public:avm/res/web/serverfarm:0.2.4' = {
  scope: rg
  name: 'planDeployment'
  params: {
    name: 'asp-${functionAppName}'
    location: location
    skuName: 'Y1' // Consumption
    reserved: true
  }
}

// Log Analytics Workspace Module
module workspace 'br/public:avm/res/operational-insights/workspace:0.7.0' = {
  scope: rg
  name: 'lawDeployment'
  params: {
    name: 'law-${functionAppName}'
    location: location
    skuName: 'PerGB2018'
  }
}

// Application Insights Module
module appInsights 'br/public:avm/res/insights/component:0.4.1' = {
  scope: rg
  name: 'aiDeployment'
  params: {
    name: 'ai-${functionAppName}'
    location: location
    workspaceResourceId: workspace.outputs.resourceId
  }
}

// Function App Module
// Note: AVM site module parameters might vary slightly per version. Using standard properties.
module functionApp 'br/public:avm/res/web/site:0.9.0' = {
  scope: rg
  name: 'funcDeployment'
  params: {
    name: functionAppName
    location: location
    kind: 'functionapp,linux'
    // serverFarmResourceId is the output from serverfarm module 
    serverFarmResourceId: appServicePlan.outputs.resourceId
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          // Construct connection string. AVM output for storage keys might need verification.
          // Assuming standard output structure.
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${listKeys(storage.outputs.resourceId, '2021-09-01').keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
           name: 'FUNCTIONS_EXTENSION_VERSION'
           value: '~4'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.outputs.instrumentationKey
        }
        {
           name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
           value: appInsights.outputs.connectionString
        }
      ]
      linuxFxVersion: 'PYTHON|3.11'
    }
    managedIdentities: {
        systemAssigned: true
    }
  }
}

// Output Function App Name
output functionAppName string = functionAppName
