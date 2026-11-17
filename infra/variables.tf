variable "subscription_id" {
  description = "Azure subscription ID. Leave null to use the ARM_SUBSCRIPTION_ID environment variable."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region for all resources. Must be a region where Azure AI Gateway is available."
  type        = string
  default     = "swedencentral"

  validation {
    condition = contains([
      "australiaeast", "canadaeast", "centralus", "eastus", "eastus2", "francecentral",
      "japaneast", "northcentralus", "northeurope", "southcentralus", "southeastasia",
      "swedencentral", "uksouth", "westeurope", "westus", "westus2",
    ], var.location)
    error_message = "Choose a region where Azure AI Gateway is available (see docs: Regional availability)."
  }
}

variable "name_prefix" {
  description = "Prefix for resource and app registration names. A random suffix is appended."
  type        = string
  default     = "aigwobo"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,11}$", var.name_prefix))
    error_message = "Use 3-12 lowercase letters or digits, starting with a letter."
  }
}

variable "tags" {
  description = "Extra tags applied to Azure resources."
  type        = map(string)
  default     = {}
}

variable "mcp_server_name" {
  description = "Name of the AI Gateway MCP server. It becomes part of the gateway MCP endpoint URL."
  type        = string
  default     = "dummy-mcp"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,62}$", var.mcp_server_name))
    error_message = "Use lowercase letters, digits and hyphens."
  }
}

variable "mcp_tool_namespace" {
  description = "Namespace prefixed to the backend's tool names on the gateway (<namespace>_<tool>)."
  type        = string
  default     = "dummy"
}

variable "mcp_protocol_versions" {
  description = "MCP protocol versions the gateway MCP server advertises. Only list versions the backend supports; M365 Copilot proposes 2025-11-25."
  type        = list(string)
  default     = ["2025-11-25", "2025-06-18", "2025-03-26"]
}

variable "backend_scope_name" {
  description = "Delegated scope exposed by the MCP backend app registration and requested by the gateway during OBO."
  type        = string
  default     = "user_impersonation"
}

variable "mcp_min_replicas" {
  description = "Minimum MCP backend replicas. Keep 1 to avoid cold starts during Copilot tool discovery."
  type        = number
  default     = 1
}

variable "enable_easy_auth" {
  description = "Enable Container Apps built-in authentication (Easy Auth) with the backend app registration in front of the MCP server."
  type        = bool
  default     = true
}

variable "grant_runtime_access_to_current_user" {
  description = "Assign 'AI Gateway Tools User' on the MCP server to the identity running Terraform."
  type        = bool
  default     = true
}

variable "runtime_access_principal_ids" {
  description = "Object IDs of additional users or groups that may invoke the MCP server through the gateway."
  type        = list(string)
  default     = []
}

variable "enable_copilot_connector" {
  description = "Create the Entra client app used by the Microsoft 365 Copilot / Copilot Cowork federated connector."
  type        = bool
  default     = true
}

variable "copilot_client_secret_lifetime" {
  description = "Lifetime of the Copilot connector client secret (Go duration, e.g. 4320h = 180 days)."
  type        = string
  default     = "4320h"
}

variable "write_vscode_mcp_config" {
  description = "Write ../.vscode/mcp.json so GitHub Copilot in VS Code can call the gateway MCP endpoint (prompts for a gateway token)."
  type        = bool
  default     = true
}

variable "image_build_mode" {
  description = "How to build the MCP server image: auto (ACR Tasks, fall back to local Docker), acr, or local."
  type        = string
  default     = "auto"

  validation {
    condition     = contains(["auto", "acr", "local"], var.image_build_mode)
    error_message = "Use auto, acr or local."
  }
}

variable "local_build_pypi_index_url" {
  description = "Optional PyPI mirror used only for local Docker builds (e.g. when files.pythonhosted.org is blocked)."
  type        = string
  default     = ""
}
