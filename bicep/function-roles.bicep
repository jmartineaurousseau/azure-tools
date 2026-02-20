param principalId string

// Storage Blob Data Owner
resource storageRoleAssignmentBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, 'Storage Blob Data Owner', principalId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Queue Data Contributor
resource storageRoleAssignmentQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, 'Storage Queue Data Contributor', principalId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Table Data Contributor
resource storageRoleAssignmentTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, 'Storage Table Data Contributor', principalId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319cd167f43')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
