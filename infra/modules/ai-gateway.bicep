// Azure AI Gateway (Microsoft.ApiManagement/aigateways) with an MCP server whose backend uses
// Entra On-Behalf-Of through the token exchange app + user-assigned managed identity.
param baseName string
param location string
param tags object

@description('Resource ID of the user-assigned identity attached to the gateway.')
param identityId string

@description('Client ID of that identity (the federated credential subject uses its principal ID).')
param identityClientId string

param tokenExchangeAppId string

@description('Complete delegated backend scope. The gateway rejects /.default for OBO.')
param backendScope string

param mcpBackendUrl string
param mcpServerName string
param mcpToolNamespace string
param mcpProtocolVersions array
param runtimePrincipalIds array

var toolsUserRoleId = 'dce03f8d-857f-4e40-a90d-67770fa6ecd2' // AI Gateway Tools User

#disable-next-line BCP081
resource aiGateway 'Microsoft.ApiManagement/aigateways@2026-11-01' = {
  name: 'aigw-${baseName}'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {}
}

#disable-next-line BCP081
resource mcpServer 'Microsoft.ApiManagement/aigateways/workspaces/toolServers@2026-11-01' = {
  name: '${aiGateway.name}/default/${mcpServerName}'
  properties: {
    toolServerType: 'mcp'
    displayName: 'Dummy MCP (user OBO)'
    description: 'Dummy MCP server on Azure Container Apps, called as the signed-in user via Entra On-Behalf-Of.'
    accessState: 'active'
    versions: mcpProtocolVersions
    allowList: [
      '*'
    ]
    endpoints: [
      {
        namespace: mcpToolNamespace
        kind: 'mcp'
        // failClosed = required backend: tool discovery fails if this backend is unavailable.
        mode: 'failClosed'
        mcp: {
          endpoint: {
            url: mcpBackendUrl
          }
          transport: 'streamableHttp'
        }
        authentication: {
          oauth2: {
            grantType: 'tokenExchange'
            tokenExchange: {
              profile: 'entraOnBehalfOf'
              federatedClientApplication: {
                applicationId: tokenExchangeAppId
                appCredential: {
                  type: 'userAssignedManagedIdentity'
                  clientId: identityClientId
                }
              }
              scopes: [
                backendScope
              ]
            }
          }
        }
      }
    ]
  }
}

// Runtime access: Owner/Contributor don't grant tool invocation through the gateway.
resource toolsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in runtimePrincipalIds: {
    name: guid(mcpServer.id, principalId, toolsUserRoleId)
    scope: mcpServer
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', toolsUserRoleId)
      principalId: principalId
    }
  }
]

var hostname = aiGateway.properties.frontend.defaultHostname

output name string = aiGateway.name
output hostname string = hostname
output mcpEndpointUrl string = mcpServer.properties.?mcpEndpointUrl ?? 'https://${hostname}/default/toolservers/${mcpServerName}/mcp'
