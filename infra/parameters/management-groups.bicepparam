using '../management-groups.bicep'

param suffix = 'alpha'

param managementGroups = [
{
    name: 'intermediary-root'
    displayName: 'Intermediary-Root'
    parentId: '11111111-1111-1111-1111-111111111111'
  }
  {
    name: 'platform-lz'
    displayName: 'Platform'
    parentId: 'intermediary-root'
  }
  {
    name: 'management'
    displayName: 'Management'
    parentId: 'platform-lz'
  }
  {
    name: 'connectivity'
    displayName: 'Connectivity'
    parentId: 'platform-lz'
  }
  {
    name: 'identity'
    displayName: 'Identity'
    parentId: 'platform-lz'
  }
  {
    name: 'application-lz'
    displayName: 'Application'
    parentId: 'intermediary-root'
  }
  {
    name: 'default'
    displayName: 'Default'
    parentId: 'intermediary-root'
  }
  {
    name: 'sandboxes'
    displayName: 'Sandboxes'
    parentId: 'intermediary-root'
  }
]
