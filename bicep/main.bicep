targetScope = 'subscription'

@description('The name of the resource group to deploy to')
param resourceGroupName string = 'rg-azure-tools'

@description('The location to deploy resources to')
param location string = 'canadacentral'

@description('The name of the function app')
param functionAppName string

@description('The name of the storage account')
param storageAccountName string

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
    skuName: 'FC1' // Flex Consumption
    reserved: true
  }
}

// Function App Module
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
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccountName
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
           name: 'FUNCTIONS_EXTENSION_VERSION'
           value: '~4'
        }
      ]
      linuxFxVersion: 'PYTHON|3.11'
    }
    managedIdentities: {
        systemAssigned: true
    }
  }
}

// Role Assignments for Function App Identity (System Assigned)
module functionRoleAssignments 'function-roles.bicep' = {
  name: 'function-roles'
  scope: rg
  params: {
    principalId: functionApp.outputs.systemAssignedMIPrincipalId
  }
}

// Output Function App Name
output functionAppName string = functionAppName
