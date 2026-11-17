// Dummy MCP server on Azure Container Apps. The image is built by an ACR Tasks run
// from the Git context in sourceLocation (no local Docker needed).
param baseName string
param location string
param tags object

@description('Resource ID of the user-assigned identity used to pull from ACR.')
param identityId string
param identityPrincipalId string

@description('Client ID of the backend app registration (App C): the expected token audience.')
param backendAppId string

@description('Client ID of the token exchange app (App B): the only allowed client app (azp).')
param tokenExchangeAppId string

param backendScopeName string
param minReplicas int
param enableEasyAuth bool
param sourceLocation string
param imageTag string

var tenantId = tenant().tenantId
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var imageName = 'mcp-server:${imageTag}'

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${baseName}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  #disable-next-line BCP334 // baseName is always at least 9 characters
  name: take(replace('acr${baseName}', '-', ''), 50)
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, identityPrincipalId, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ACR Tasks quick build; the deployment waits for the run to finish.
resource image 'Microsoft.ContainerRegistry/registries/taskRuns@2019-06-01-preview' = {
  parent: acr
  name: 'build-mcp-server'
  location: location
  properties: {
    forceUpdateTag: imageTag
    runRequest: {
      type: 'DockerBuildRequest'
      sourceLocation: sourceLocation
      dockerFilePath: 'Dockerfile'
      imageNames: [imageName]
      isPushEnabled: true
      platform: {
        os: 'Linux'
        architecture: 'amd64'
      }
    }
  }
}

resource containerEnv 'Microsoft.App/managedEnvironments@2025-07-01' = {
  name: 'cae-${baseName}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

resource app 'Microsoft.App/containerApps@2025-07-01' = {
  name: 'ca-${baseName}-mcp'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    environmentId: containerEnv.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: identityId
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'mcp-server'
          image: '${acr.properties.loginServer}/${imageName}'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            {
              name: 'AZURE_TENANT_ID'
              value: tenantId
            }
            {
              name: 'BACKEND_CLIENT_ID'
              value: backendAppId
            }
            {
              name: 'REQUIRED_SCOPE'
              value: backendScopeName
            }
            {
              // Only tokens obtained by the gateway's token exchange app are accepted.
              name: 'ALLOWED_CLIENT_IDS'
              value: tokenExchangeAppId
            }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/healthz'
                port: 8000
              }
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/healthz'
                port: 8000
              }
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: 3
      }
    }
  }
  dependsOn: [
    image
    acrPull
  ]
}

// Container Apps built-in authentication ("Easy Auth"): the platform validates the bearer token
// against the backend app registration before requests reach the container. The in-code checks
// in server.py still run (defense in depth) and read the user's claims for the tools.
resource auth 'Microsoft.App/containerApps/authConfigs@2025-07-01' = if (enableEasyAuth) {
  parent: app
  name: 'current'
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      unauthenticatedClientAction: 'Return401'
      excludedPaths: [
        '/healthz'
      ]
    }
    httpSettings: {
      requireHttps: true
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: backendAppId
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenantId}/v2.0'
        }
        validation: {
          // v2 tokens carry the bare client ID as audience.
          allowedAudiences: [
            backendAppId
          ]
          defaultAuthorizationPolicy: {
            // Only tokens requested by the gateway's token exchange app (OBO).
            allowedApplications: [
              tokenExchangeAppId
            ]
          }
        }
      }
    }
  }
}

output mcpUrl string = 'https://${app.properties.configuration.ingress.fqdn}/mcp'
output registryName string = acr.name
