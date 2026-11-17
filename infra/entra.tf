# Entra ID objects for the On-Behalf-Of chain:
#   Copilot user token (aud = AI Gateway, scp = Data.All)
#     -> AI Gateway exchanges it via the token exchange app (FederationApp.Access),
#        authenticating as that app with its user-assigned managed identity (no secret)
#     -> backend token (aud = MCP backend app, scp = user_impersonation, azp = token exchange app)

locals {
  ai_gateway_app_id      = "18550318-e177-4205-a743-6816d6fcdc3f" # Azure AI Gateway Dataplane (Microsoft first-party)
  microsoft_graph_app_id = "00000003-0000-0000-c000-000000000000"
  entra_authority        = "https://login.microsoftonline.com/${local.tenant_id}"
  backend_scope          = "api://${azuread_application.backend.client_id}/${var.backend_scope_name}"
}

# First-party service principal: created when missing, never deleted on destroy
# (other gateways in the tenant depend on it).
resource "terraform_data" "ai_gateway_service_principal" {
  input = local.ai_gateway_app_id

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/ensure-service-principal.sh ${self.input}"
  }
}

data "azuread_service_principal" "ai_gateway" {
  client_id  = local.ai_gateway_app_id
  depends_on = [terraform_data.ai_gateway_service_principal]
}

data "azuread_service_principal" "msgraph" {
  client_id = local.microsoft_graph_app_id
}

resource "random_uuid" "backend_scope_id" {}

resource "random_uuid" "token_exchange_scope_id" {}

# ---------------------------------------------------------------------------
# MCP backend API (validates the OBO token)
# ---------------------------------------------------------------------------
resource "azuread_application" "backend" {
  display_name     = "${local.base_name}-mcp-backend"
  sign_in_audience = "AzureADMyOrg"
  owners           = local.owners

  api {
    # v2 tokens: aud = client ID (GUID), iss = login.microsoftonline.com/<tenant>/v2.0
    requested_access_token_version = 2

    oauth2_permission_scope {
      id                         = random_uuid.backend_scope_id.result
      value                      = var.backend_scope_name
      type                       = "User"
      enabled                    = true
      admin_consent_display_name = "Call the MCP backend as the signed-in user"
      admin_consent_description  = "Allows the AI Gateway token exchange app to call the MCP backend on behalf of the signed-in user."
      user_consent_display_name  = "Call the MCP backend as you"
      user_consent_description   = "Allows the app to call the MCP backend on your behalf."
    }
  }

  lifecycle {
    ignore_changes = [identifier_uris]
  }
}

resource "azuread_application_identifier_uri" "backend" {
  application_id = azuread_application.backend.id
  identifier_uri = "api://${azuread_application.backend.client_id}"
}

resource "azuread_service_principal" "backend" {
  client_id = azuread_application.backend.client_id
  owners    = local.owners
}

# ---------------------------------------------------------------------------
# Token exchange app (performs OBO for the gateway)
# ---------------------------------------------------------------------------
resource "azuread_application" "token_exchange" {
  display_name     = "${local.base_name}-token-exchange"
  sign_in_audience = "AzureADMyOrg"
  owners           = local.owners

  api {
    requested_access_token_version = 2

    oauth2_permission_scope {
      id                         = random_uuid.token_exchange_scope_id.result
      value                      = "FederationApp.Access"
      type                       = "User"
      enabled                    = true
      admin_consent_display_name = "Exchange user tokens through Azure AI Gateway"
      admin_consent_description  = "Allows Azure AI Gateway to exchange the signed-in user's token through this app."
      user_consent_display_name  = "Let Azure AI Gateway act on your behalf"
      user_consent_description   = "Allows Azure AI Gateway to call backend tools on your behalf."
    }
  }

  # Delegated permission on the backend; consented tenant-wide below.
  required_resource_access {
    resource_app_id = azuread_application.backend.client_id

    resource_access {
      id   = random_uuid.backend_scope_id.result
      type = "Scope"
    }
  }

  lifecycle {
    ignore_changes = [identifier_uris]
  }
}

resource "azuread_application_identifier_uri" "token_exchange" {
  application_id = azuread_application.token_exchange.id
  identifier_uri = "api://${azuread_application.token_exchange.client_id}"
}

resource "azuread_service_principal" "token_exchange" {
  client_id = azuread_application.token_exchange.client_id
  owners    = local.owners
}

# Secretless credential: the gateway's user-assigned identity signs in as the token exchange app.
resource "azuread_application_federated_identity_credential" "token_exchange_gateway_identity" {
  application_id = azuread_application.token_exchange.id
  display_name   = "ai-gateway-${random_string.suffix.result}"
  description    = "Azure AI Gateway user-assigned managed identity ${azurerm_user_assigned_identity.gateway.name}"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "${local.entra_authority}/v2.0"
  # Principal (object) ID of the managed identity - not its client ID.
  subject = azurerm_user_assigned_identity.gateway.principal_id
}

# Directory writes are eventually consistent; give new service principals time to replicate.
resource "time_sleep" "entra_replication" {
  create_duration = "30s"

  depends_on = [
    azuread_service_principal.backend,
    azuread_service_principal.token_exchange,
    azuread_application_identifier_uri.backend,
    azuread_application_identifier_uri.token_exchange,
  ]
}

# Azure AI Gateway may request FederationApp.Access without a consent prompt.
resource "azuread_application_pre_authorized" "token_exchange_ai_gateway" {
  application_id       = azuread_application.token_exchange.id
  authorized_client_id = data.azuread_service_principal.ai_gateway.client_id
  permission_ids       = [random_uuid.token_exchange_scope_id.result]

  depends_on = [time_sleep.entra_replication]
}

# The backend trusts the token exchange app as an authorized client.
resource "azuread_application_pre_authorized" "backend_token_exchange" {
  application_id       = azuread_application.backend.id
  authorized_client_id = azuread_application.token_exchange.client_id
  permission_ids       = [random_uuid.backend_scope_id.result]

  depends_on = [time_sleep.entra_replication]
}

# Tenant-wide admin consent for the OBO hop (token exchange app -> backend scope).
resource "azuread_service_principal_delegated_permission_grant" "token_exchange_to_backend" {
  service_principal_object_id          = azuread_service_principal.token_exchange.object_id
  resource_service_principal_object_id = azuread_service_principal.backend.object_id
  claim_values                         = [var.backend_scope_name]

  depends_on = [time_sleep.entra_replication]
}
