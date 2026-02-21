@description('The location to deploy resources to')
param location string = resourceGroup().location

@description('The name of the function app')
param functionAppName string

@description('The name of the storage account')
param storageAccountName string

@description('Whether to deploy application insights')
param deployAppInsights bool = false

// Storage Account Module
module storage 'br/public:avm/res/storage/storage-account:0.9.1' = {
  name: 'storageDeployment'
  params: {
    name: storageAccountName
    location: location
    skuName: 'Standard_LRS'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    blobServices: {
      containers: [
        {
          name: 'app-package'
          publicAccess: 'None'
        }
      ]
    }
  }
}


// Log Analytics Workspace
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = if(deployAppInsights) {
  name: 'law-${functionAppName}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
}

// Application Insights
resource appInsights 'Microsoft.Insights/components@2020-02-02' = if(deployAppInsights) {
  name: 'appi-${functionAppName}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: deployAppInsights ? logAnalytics.id : ''
  }
}


// App Service Plan Module
module appServicePlan 'br/public:avm/res/web/serverfarm:0.2.4' = {
  name: 'planDeployment'
  params: {
    name: 'asp-${functionAppName}'
    location: location
    skuName: 'FC1' // Flex Consumption
    reserved: true
  }
}

// Function App Module
module functionApp 'br/public:avm/res/web/site:0.13.0' = {
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
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccountName
        }
        {
          name: 'WEBSITE_TIME_ZONE'
          value: 'Eastern Standard Time'
        }
      ]
    }
    managedIdentities: {
        systemAssigned: true
    }
    appInsightResourceId: deployAppInsights ? appInsights.id : ''
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: 'https://${storageAccountName}.blob.${environment().suffixes.storage}/app-package'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 40
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
    }
  }
}

// Role Assignments for Function App Identity (System Assigned)
module functionRoleAssignments 'function-roles.bicep' = {
  name: 'function-roles'
  params: {
    principalId: functionApp.outputs.systemAssignedMIPrincipalId
  }
}

// Output Function App Name
output functionAppName string = functionAppName
