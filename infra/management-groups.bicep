targetScope = 'managementGroup'

@description('Suffix to append to all management group names')
param suffix string

@description('Array of management groups to deploy. Each object should have a name, displayName, and optionally a parentId.')
param managementGroups array = []

@batchSize(1)
module mgs 'br/public:avm/res/management/management-group:0.1.2' = [for mg in managementGroups: {
  name: 'deploy-${mg.name}-${suffix}'
  params: {
    name: '${mg.name}-${suffix}'
    displayName: '${mg.displayName} ${suffix}'
    // If parentId length is 36, treat it as a GUID (like tenant ID or existing MG), otherwise assume it's an internal reference and append suffix
    parentId: contains(mg, 'parentId') ? (length(mg.parentId) == 36 ? mg.parentId : '${mg.parentId}-${suffix}') : tenant().tenantId
  }
}]
