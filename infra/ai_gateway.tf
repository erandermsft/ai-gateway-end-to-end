# Azure AI Gateway (Microsoft.ApiManagement/aigateways) with a federated MCP server whose
# backend uses Entra On-Behalf-Of through the token exchange app + user-assigned identity.

locals {
  ai_gateway_api_version        = "2026-11-01"
  ai_gateway_tools_user_role_id = "dce03f8d-857f-4e40-a90d-67770fa6ecd2" # AI Gateway Tools User

  ai_gateway_hostname = azapi_resource.ai_gateway.output.properties.frontend.defaultHostname
  mcp_endpoint_url = coalesce(
    try(azapi_resource.mcp_server.output.properties.mcpEndpointUrl, null),
    try([for e in azapi_resource.mcp_server.output.properties.gatewayEndpoints : e.url if lower(try(e.api, "")) == "mcp"][0], null),
    "https://${local.ai_gateway_hostname}/default/toolservers/${var.mcp_server_name}/mcp",
  )

  runtime_principal_ids = toset(concat(
    var.grant_runtime_access_to_current_user ? [data.azuread_client_config.current.object_id] : [],
    var.runtime_access_principal_ids,
  ))
}

resource "azapi_resource" "ai_gateway" {
  type      = "Microsoft.ApiManagement/aigateways@${local.ai_gateway_api_version}"
  name      = "aigw-${local.base_name}"
  parent_id = azurerm_resource_group.this.id
  location  = azurerm_resource_group.this.location
  tags      = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.gateway.id]
  }

  body = {
    properties = {}
  }

  schema_validation_enabled = false
  response_export_values    = ["properties.frontend.defaultHostname"]
}

resource "azapi_resource" "mcp_server" {
  type      = "Microsoft.ApiManagement/aigateways/workspaces/toolServers@${local.ai_gateway_api_version}"
  name      = var.mcp_server_name
  parent_id = "${azapi_resource.ai_gateway.id}/workspaces/default"

  body = {
    properties = {
      toolServerType = "mcp"
      displayName    = "Dummy MCP (user OBO)"
      description    = "Dummy MCP server on Azure Container Apps, called as the signed-in user via Entra On-Behalf-Of."
      accessState    = "active"
      versions       = var.mcp_protocol_versions
      allowList      = ["*"]

      endpoints = [
        {
          namespace = var.mcp_tool_namespace
          kind      = "mcp"
          # failClosed = required backend: tool discovery fails if this backend is unavailable.
          mode = "failClosed"

          mcp = {
            endpoint  = { url = local.mcp_backend_url }
            transport = "streamableHttp"
          }

          authentication = {
            oauth2 = {
              grantType = "tokenExchange"
              tokenExchange = {
                profile = "entraOnBehalfOf"
                federatedClientApplication = {
                  applicationId = azuread_application.token_exchange.client_id
                  appCredential = {
                    type = "userAssignedManagedIdentity"
                    # Client ID here; the federated credential subject uses the principal ID.
                    clientId = azurerm_user_assigned_identity.gateway.client_id
                  }
                }
                # Explicit delegated scope - the gateway rejects /.default for OBO.
                scopes = [local.backend_scope]
              }
            }
          }
        },
      ]
    }
  }

  schema_validation_enabled = false
  response_export_values    = ["properties.mcpEndpointUrl", "properties.gatewayEndpoints"]

  depends_on = [
    azuread_application_federated_identity_credential.token_exchange_gateway_identity,
    azuread_application_pre_authorized.token_exchange_ai_gateway,
    azuread_application_pre_authorized.backend_token_exchange,
    azuread_service_principal_delegated_permission_grant.token_exchange_to_backend,
  ]
}

# Runtime access: Owner/Contributor don't grant tool invocation through the gateway.
resource "azurerm_role_assignment" "mcp_tools_user" {
  for_each = local.runtime_principal_ids

  scope              = azapi_resource.mcp_server.id
  role_definition_id = "/subscriptions/${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.ai_gateway_tools_user_role_id}"
  principal_id       = each.value
}
