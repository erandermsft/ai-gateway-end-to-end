# Entra client app used by the Microsoft 365 Copilot / Copilot Cowork federated connector.
# Copilot signs the user in (OAuth 2.0 auth code + PKCE) and gets a delegated token for
# https://ai.gateway.azure.com/Data.All, which it sends to the gateway MCP endpoint.
# The Teams Developer Portal OAuth registration and the connector itself are created manually
# (see README) using the values from the `copilot_connector` outputs.

locals {
  teams_oauth_redirect_uri = "https://teams.microsoft.com/api/platform/v1.0/oAuthRedirect"
  copilot_connector_scopes = "https://ai.gateway.azure.com/Data.All offline_access"
}

resource "azuread_application" "copilot_connector" {
  count = var.enable_copilot_connector ? 1 : 0

  display_name     = "${local.base_name}-copilot-connector"
  sign_in_audience = "AzureADMyOrg"
  owners           = local.owners

  web {
    # OAuth 2.0 connectors use oAuthRedirect (Entra SSO connectors use oAuthConsentRedirect).
    redirect_uris = [local.teams_oauth_redirect_uri]
  }

  required_resource_access {
    resource_app_id = local.ai_gateway_app_id

    resource_access {
      id   = data.azuread_service_principal.ai_gateway.oauth2_permission_scope_ids["Data.All"]
      type = "Scope"
    }
  }

  # Lets Teams refresh expired tokens.
  required_resource_access {
    resource_app_id = local.microsoft_graph_app_id

    resource_access {
      id   = data.azuread_service_principal.msgraph.oauth2_permission_scope_ids["openid"]
      type = "Scope"
    }

    resource_access {
      id   = data.azuread_service_principal.msgraph.oauth2_permission_scope_ids["offline_access"]
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "copilot_connector" {
  count = var.enable_copilot_connector ? 1 : 0

  client_id = azuread_application.copilot_connector[0].client_id
  owners    = local.owners
}

resource "time_static" "copilot_connector_secret" {
  count = var.enable_copilot_connector ? 1 : 0
}

resource "azuread_application_password" "copilot_connector" {
  count = var.enable_copilot_connector ? 1 : 0

  application_id = azuread_application.copilot_connector[0].id
  display_name   = "teams-developer-portal-oauth"
  end_date       = timeadd(time_static.copilot_connector_secret[0].rfc3339, var.copilot_client_secret_lifetime)
}

resource "time_sleep" "copilot_connector_replication" {
  count = var.enable_copilot_connector ? 1 : 0

  create_duration = "30s"
  depends_on      = [azuread_service_principal.copilot_connector]
}

# Tenant-wide admin consent so users aren't blocked by consent prompts in Copilot.
resource "azuread_service_principal_delegated_permission_grant" "copilot_connector_ai_gateway" {
  count = var.enable_copilot_connector ? 1 : 0

  service_principal_object_id          = azuread_service_principal.copilot_connector[0].object_id
  resource_service_principal_object_id = data.azuread_service_principal.ai_gateway.object_id
  claim_values                         = ["Data.All"]

  depends_on = [time_sleep.copilot_connector_replication]
}

resource "azuread_service_principal_delegated_permission_grant" "copilot_connector_graph" {
  count = var.enable_copilot_connector ? 1 : 0

  service_principal_object_id          = azuread_service_principal.copilot_connector[0].object_id
  resource_service_principal_object_id = data.azuread_service_principal.msgraph.object_id
  claim_values                         = ["openid", "offline_access"]

  depends_on = [time_sleep.copilot_connector_replication]
}
