#!/usr/bin/env python3
"""End-to-end check of: signed-in user -> Azure AI Gateway -> On-Behalf-Of -> MCP backend.

Gets a delegated gateway token from the Azure CLI (same audience and scope as the token a
Microsoft 365 Copilot connector sends), lists tools through the gateway MCP endpoint, calls
whoami, and verifies the backend received *your* identity in a token issued to the token
exchange app for the backend audience. Standard library only.

Usage: python3 scripts/test-obo.py   (run after `terraform -chdir=infra apply`)
"""

from __future__ import annotations

import base64
import json
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

GATEWAY_SCOPE = "https://ai.gateway.azure.com/Data.All"
PROTOCOL_VERSION = "2025-11-25"  # the version Microsoft 365 Copilot proposes
INFRA_DIR = Path(__file__).resolve().parent.parent / "infra"


def run(*cmd: str) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def terraform_outputs() -> dict[str, Any]:
    raw = json.loads(run("terraform", f"-chdir={INFRA_DIR}", "output", "-json"))
    return {name: item["value"] for name, item in raw.items()}


def jwt_claims(token: str) -> dict[str, Any]:
    payload = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))


class McpClient:
    def __init__(self, url: str, token: str | None) -> None:
        self.url = url
        self.token = token
        self.session_id: str | None = None
        self.protocol_version: str | None = None
        self._next_id = 0

    def _post(self, payload: dict[str, Any]) -> dict[str, Any] | None:
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        if self.protocol_version:
            headers["MCP-Protocol-Version"] = self.protocol_version

        request = urllib.request.Request(
            self.url, data=json.dumps(payload).encode(), headers=headers, method="POST"
        )
        with urllib.request.urlopen(request, timeout=90) as response:
            self.session_id = response.headers.get("Mcp-Session-Id") or self.session_id
            content_type = response.headers.get("Content-Type", "")
            body = response.read().decode()

        if not body.strip():
            return None
        if "text/event-stream" in content_type:
            messages = [
                json.loads(line[5:])
                for line in body.splitlines()
                if line.startswith("data:") and line[5:].strip()
            ]
            matching = [m for m in messages if m.get("id") == payload.get("id")]
            return (matching or messages or [None])[-1]
        return json.loads(body)

    def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        self._next_id += 1
        message = self._post({"jsonrpc": "2.0", "id": self._next_id, "method": method, "params": params or {}})
        if message is None:
            raise RuntimeError(f"{method}: empty response")
        if "error" in message:
            raise RuntimeError(f"{method} failed: {message['error']}")
        return message["result"]

    def notify(self, method: str) -> None:
        self._post({"jsonrpc": "2.0", "method": method})


def http_status(url: str, token: str | None) -> tuple[int, dict[str, str]]:
    client = McpClient(url, token)
    try:
        client.request("tools/list")
        return 200, {}
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers)


def tool_result(result: dict[str, Any]) -> dict[str, Any]:
    if isinstance(result.get("structuredContent"), dict):
        return result["structuredContent"]
    text = next((c["text"] for c in result.get("content", []) if c.get("type") == "text"), "{}")
    return json.loads(text)


def main() -> int:
    outputs = terraform_outputs()
    gateway_url = outputs["mcp_endpoint_url"]
    print(f"Gateway MCP endpoint: {gateway_url}")

    status, headers = http_status(gateway_url, None)
    print(f"\n[1] Anonymous call -> HTTP {status}")
    challenge = headers.get("WWW-Authenticate") or headers.get("www-authenticate")
    if challenge:
        print(f"    WWW-Authenticate: {challenge}")

    token = run("az", "account", "get-access-token", "--scope", GATEWAY_SCOPE, "--query", "accessToken", "-o", "tsv")
    claims = jwt_claims(token)
    print(f"\n[2] Gateway token: aud={claims.get('aud')} scp={claims.get('scp')} azp={claims.get('azp')} user={claims.get('preferred_username')}")

    client = McpClient(gateway_url, token)
    init = client.request(
        "initialize",
        {"protocolVersion": PROTOCOL_VERSION, "capabilities": {}, "clientInfo": {"name": "obo-e2e-test", "version": "1.0"}},
    )
    client.protocol_version = init.get("protocolVersion")
    client.notify("notifications/initialized")
    print(f"\n[3] initialize -> protocol {client.protocol_version}, server {init.get('serverInfo', {}).get('name')}")

    tools = [tool["name"] for tool in client.request("tools/list").get("tools", [])]
    print(f"[4] tools/list -> {tools}")
    whoami_tool = next((name for name in tools if name.endswith("whoami")), None)
    if not whoami_tool:
        print("FAIL: whoami tool not found")
        return 1

    who = tool_result(client.request("tools/call", {"name": whoami_tool, "arguments": {}}))
    print(f"[5] {whoami_tool} ->\n{json.dumps(who, indent=2)}")

    backend_status, _ = http_status(outputs["mcp_backend_url"], token)
    print(f"\n[6] Gateway token sent straight to the backend -> HTTP {backend_status}")

    me = run("az", "ad", "signed-in-user", "show", "--query", "id", "-o", "tsv")
    checks = {
        "anonymous gateway call is rejected (401)": status == 401,
        "backend saw the signed-in user (oid)": who.get("object_id") == me,
        "backend token audience is the backend app": who.get("audience") == outputs["backend_app_client_id"],
        "backend token was requested by the token exchange app (azp)": who.get("client_app_id") == outputs["token_exchange_app_client_id"],
        "backend token carries the delegated scope": outputs["backend_scope"].rsplit("/", 1)[-1] in str(who.get("scopes", "")).split(),
        "backend rejects tokens that bypass the gateway": backend_status == 401,
    }
    print()
    for name, ok in checks.items():
        print(f"{'PASS' if ok else 'FAIL'}  {name}")
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
