output "tenant_id" {
  value = local.tenant_id
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "ai_gateway_name" {
  value = azapi_resource.ai_gateway.name
}

output "ai_gateway_hostname" {
  value = local.ai_gateway_hostname
}

output "mcp_endpoint_url" {
  description = "Gateway MCP endpoint: use it as the connector Base URL (Copilot) or MCP server URL (VS Code)."
  value       = local.mcp_endpoint_url
}

output "mcp_backend_url" {
  description = "Container App MCP endpoint (rejects any token that didn't come through the gateway's OBO exchange)."
  value       = local.mcp_backend_url
}

output "backend_app_client_id" {
  value = azuread_application.backend.client_id
}

output "backend_scope" {
  value = local.backend_scope
}

output "token_exchange_app_client_id" {
  value = azuread_application.token_exchange.client_id
}

output "gateway_managed_identity" {
  value = {
    resource_id  = azurerm_user_assigned_identity.gateway.id
    client_id    = azurerm_user_assigned_identity.gateway.client_id
    principal_id = azurerm_user_assigned_identity.gateway.principal_id
  }
}

output "copilot_connector" {
  description = "Values for the Teams Developer Portal OAuth client registration and the M365 federated connector."
  value = var.enable_copilot_connector ? {
    client_id              = azuread_application.copilot_connector[0].client_id
    client_secret          = "terraform output -raw copilot_connector_client_secret"
    base_url               = local.mcp_endpoint_url
    authorization_endpoint = "${local.entra_authority}/oauth2/v2.0/authorize"
    token_endpoint         = "${local.entra_authority}/oauth2/v2.0/token"
    refresh_endpoint       = "${local.entra_authority}/oauth2/v2.0/token"
    scopes                 = local.copilot_connector_scopes
    pkce                   = "Enabled"
    restrict_usage_by_org  = "My organization only"
    restrict_usage_by_app  = "Any Teams app"
    redirect_uri           = local.teams_oauth_redirect_uri
  } : null
}

output "copilot_connector_client_secret" {
  value     = var.enable_copilot_connector ? azuread_application_password.copilot_connector[0].value : null
  sensitive = true
}
