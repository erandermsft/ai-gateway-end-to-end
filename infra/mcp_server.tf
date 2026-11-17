# Dummy MCP server on Azure Container Apps, image built from ../mcp-server.

locals {
  acr_name = substr(replace("acr${local.base_name}", "-", ""), 0, 50)

  mcp_server_dir = abspath("${path.module}/../mcp-server")
  mcp_source_files = sort([
    for f in fileset(local.mcp_server_dir, "**") : f
    if !can(regex("(^|/)(__pycache__|\\.venv)/", f))
  ])
  # Content hash => new image tag (and a new Container App revision) whenever the source changes.
  mcp_source_hash = sha1(join(",", [for f in local.mcp_source_files : "${f}:${filesha1("${local.mcp_server_dir}/${f}")}"]))
  mcp_image_name  = "mcp-server:${substr(local.mcp_source_hash, 0, 12)}"
  mcp_image       = "${azurerm_container_registry.this.login_server}/${local.mcp_image_name}"

  mcp_backend_url = "https://${azurerm_container_app.mcp.ingress[0].fqdn}/mcp"
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.base_name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_container_registry" "this" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags
}

resource "azurerm_role_assignment" "mcp_app_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.mcp_app.principal_id
  principal_type       = "ServicePrincipal"
}

resource "time_sleep" "acr_pull_propagation" {
  create_duration = "30s"
  depends_on      = [azurerm_role_assignment.mcp_app_acr_pull]
}

resource "terraform_data" "mcp_image" {
  triggers_replace = [local.mcp_image]

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/build-image.sh"

    environment = {
      ACR_NAME        = azurerm_container_registry.this.name
      IMAGE           = local.mcp_image_name
      SOURCE_DIR      = local.mcp_server_dir
      SUBSCRIPTION_ID = local.subscription_id
      BUILD_MODE      = var.image_build_mode
      PYPI_INDEX_URL  = var.local_build_pypi_index_url
    }
  }
}

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${local.base_name}"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  logs_destination           = "log-analytics"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  tags                       = local.tags

  # Azure adds this profile by default; declaring it avoids a perpetual diff.
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_container_app" "mcp" {
  name                         = "ca-${local.base_name}-mcp"
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  workload_profile_name        = "Consumption"
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.mcp_app.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.mcp_app.id
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.mcp_min_replicas
    max_replicas = 3

    container {
      name   = "mcp-server"
      image  = local.mcp_image
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "AZURE_TENANT_ID"
        value = local.tenant_id
      }

      env {
        name  = "BACKEND_CLIENT_ID"
        value = azuread_application.backend.client_id
      }

      env {
        name  = "REQUIRED_SCOPE"
        value = var.backend_scope_name
      }

      # Only tokens obtained by the gateway's token exchange app are accepted.
      env {
        name  = "ALLOWED_CLIENT_IDS"
        value = azuread_application.token_exchange.client_id
      }

      liveness_probe {
        transport = "HTTP"
        port      = 8000
        path      = "/healthz"
      }

      readiness_probe {
        transport = "HTTP"
        port      = 8000
        path      = "/healthz"
      }
    }
  }

  depends_on = [
    terraform_data.mcp_image,
    time_sleep.acr_pull_propagation,
  ]
}

# Container Apps built-in authentication ("Easy Auth"): the platform validates the bearer token
# against the backend app registration before requests reach the container. The in-code checks
# in server.py still run (defense in depth) and read the user's claims for the tools.
resource "azapi_resource" "mcp_auth" {
  count = var.enable_easy_auth ? 1 : 0

  type      = "Microsoft.App/containerApps/authConfigs@2025-07-01"
  name      = "current"
  parent_id = azurerm_container_app.mcp.id

  body = {
    properties = {
      platform = {
        enabled = true
      }
      globalValidation = {
        unauthenticatedClientAction = "Return401"
        excludedPaths               = ["/healthz"]
      }
      httpSettings = {
        requireHttps = true
      }
      identityProviders = {
        azureActiveDirectory = {
          enabled = true
          registration = {
            clientId     = azuread_application.backend.client_id
            openIdIssuer = "${local.entra_authority}/v2.0"
          }
          validation = {
            # v2 tokens carry the bare client ID as audience.
            allowedAudiences = [azuread_application.backend.client_id]
            defaultAuthorizationPolicy = {
              # Only tokens requested by the gateway's token exchange app (OBO).
              allowedApplications = [azuread_application.token_exchange.client_id]
            }
          }
        }
      }
    }
  }
}
