// Sets an application's identifier URI to the default api://{appId}.
//
// An application declaration can't reference its own appId, so this second declaration of
// the same application (matched by uniqueName) runs once the application exists. Graph Bicep
// upserts with PATCH, so properties left out here keep their values.
extension microsoftGraphV1

param uniqueName string
param displayName string
param appId string

resource application 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: uniqueName
  displayName: displayName
  identifierUris: ['api://${appId}']
}

output appId string = application.appId
output identifierUri string = 'api://${appId}'
