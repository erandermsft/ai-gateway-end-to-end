data "azurerm_client_config" "current" {}

data "azuread_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  tenant_id       = data.azuread_client_config.current.tenant_id
  subscription_id = data.azurerm_client_config.current.subscription_id
  base_name       = "${var.name_prefix}-${random_string.suffix.result}"
  owners          = [data.azuread_client_config.current.object_id]

  tags = merge({ workload = "ai-gateway-obo-mcp" }, var.tags)
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.base_name}"
  location = var.location
  tags     = local.tags
}

# Attached to the AI Gateway; trusted by the token exchange app through a federated credential.
resource "azurerm_user_assigned_identity" "gateway" {
  name                = "id-${local.base_name}-gateway"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

# Used by the Container App to pull its image from ACR.
resource "azurerm_user_assigned_identity" "mcp_app" {
  name                = "id-${local.base_name}-mcp"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}
