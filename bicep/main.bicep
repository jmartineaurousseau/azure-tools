targetScope = 'subscription'

@description('The name of the resource group to deploy to')
param resourceGroupName string = 'rg-azure-tools'

@description('The location to deploy resources to')
param location string = 'eastus'

@description('The name of the function app')
param functionAppName string

@description('The name of the storage account')
param storageAccountName string

@description('Deploy Application Insights')
param deployAppInsights bool = true

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


// Existing Storage Account Reference (for keys)


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
module workspace 'br/public:avm/res/operational-insights/workspace:0.7.0' = if (deployAppInsights) {
  scope: rg
  name: 'lawDeployment'
  params: {
    name: 'law-${functionAppName}'
    location: location
    skuName: 'PerGB2018'
  }
}

// Application Insights Module
module appInsights 'br/public:avm/res/insights/component:0.4.1' = if (deployAppInsights) {
  scope: rg
  name: 'aiDeployment'
  params: {
    name: 'ai-${functionAppName}'
    location: location
    workspaceResourceId: workspace.outputs.resourceId
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
      appSettings: union([
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
      ], deployAppInsights ? [
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.outputs.instrumentationKey
        }
        {
           name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
           value: appInsights.outputs.connectionString
        }
      ] : [])
      linuxFxVersion: 'PYTHON|3.11'
    }
    managedIdentities: {
        systemAssigned: true
    }
  }
}

// Role Assignments for Function App Identity (System Assigned)

// Storage Blob Data Owner
resource storageRoleAssignmentBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.outputs.resourceId, 'Storage Blob Data Owner', functionApp.outputs.resourceId)
  scope: rg
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalId: functionApp.outputs.systemAssignedMIPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Queue Data Contributor
resource storageRoleAssignmentQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.outputs.resourceId, 'Storage Queue Data Contributor', functionApp.outputs.resourceId)
  scope: rg
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: functionApp.outputs.systemAssignedMIPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Table Data Contributor
resource storageRoleAssignmentTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.outputs.resourceId, 'Storage Table Data Contributor', functionApp.outputs.resourceId)
  scope: rg
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319cd167f43')
    principalId: functionApp.outputs.systemAssignedMIPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Output Function App Name
output functionAppName string = functionAppName
