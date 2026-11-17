# Optional: GitHub Copilot in VS Code can call the same gateway MCP endpoint.
# The gateway doesn't publish OAuth protected-resource metadata, so VS Code can't discover
# Entra sign-in on its own; it prompts for a gateway token instead (valid ~60-90 minutes).
resource "local_file" "vscode_mcp_json" {
  count = var.write_vscode_mcp_config ? 1 : 0

  filename        = "${path.module}/../.vscode/mcp.json"
  file_permission = "0644"
  content         = <<-EOT
    {
      "inputs": [
        {
          "type": "promptString",
          "id": "ai-gateway-token",
          "description": "Azure AI Gateway token: az account get-access-token --scope https://ai.gateway.azure.com/Data.All --query accessToken -o tsv",
          "password": true
        }
      ],
      "servers": {
        "${var.mcp_server_name}": {
          "type": "http",
          "url": "${local.mcp_endpoint_url}",
          "headers": {
            "Authorization": "Bearer $${input:ai-gateway-token}"
          }
        }
      }
    }
  EOT
}
