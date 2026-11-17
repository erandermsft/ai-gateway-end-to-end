param baseName string
param location string
param tags object

// Attached to the AI Gateway; trusted by the token exchange app through a federated credential.
resource gateway 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${baseName}-gateway'
  location: location
  tags: tags
}

// Used by the Container App to pull its image from ACR.
resource mcpApp 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${baseName}-mcp'
  location: location
  tags: tags
}

output gatewayIdentityId string = gateway.id
output gatewayClientId string = gateway.properties.clientId
output gatewayPrincipalId string = gateway.properties.principalId
output mcpAppIdentityId string = mcpApp.id
output mcpAppPrincipalId string = mcpApp.properties.principalId
