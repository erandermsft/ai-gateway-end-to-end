"""Dummy MCP server protected by Microsoft Entra ID.

The server only accepts delegated (user) v2 access tokens that:
  * are issued by the configured tenant,
  * target this backend app registration (``aud`` == backend client ID),
  * carry the backend's delegated scope (``scp``), and
  * were requested by an allow-listed client app (``azp``) - the AI Gateway
    token-exchange app that performs the On-Behalf-Of (OBO) exchange.

So the only way to reach the tools is: MCP client -> AI Gateway -> OBO -> here.
"""

from __future__ import annotations

import logging
import os
from datetime import datetime, timezone
from typing import Any

import uvicorn
from fastmcp import FastMCP
from fastmcp.server.auth.providers.jwt import JWTVerifier
from fastmcp.server.dependencies import get_access_token
from starlette.requests import Request
from starlette.responses import JSONResponse

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("mcp-backend")

TENANT_ID = os.environ["AZURE_TENANT_ID"]
BACKEND_CLIENT_ID = os.environ["BACKEND_CLIENT_ID"]
REQUIRED_SCOPE = os.getenv("REQUIRED_SCOPE", "user_impersonation")
ALLOWED_CLIENT_IDS = {
    client_id.strip().lower()
    for client_id in os.getenv("ALLOWED_CLIENT_IDS", "").split(",")
    if client_id.strip()
}
AUTHORITY_HOST = os.getenv("AUTHORITY_HOST", "https://login.microsoftonline.com").rstrip("/")
JWKS_URI = os.getenv("JWKS_URI", f"{AUTHORITY_HOST}/{TENANT_ID}/discovery/v2.0/keys")
TOKEN_ISSUER = os.getenv("TOKEN_ISSUER", f"{AUTHORITY_HOST}/{TENANT_ID}/v2.0")


class EntraOboTokenVerifier(JWTVerifier):
    """JWT verification plus an allow-list on the calling client app (``azp``)."""

    async def verify_token(self, token: str):  # type: ignore[override]
        access_token = await super().verify_token(token)
        if access_token is None:
            return None

        claims = access_token.claims
        client_app_id = str(claims.get("azp", "")).lower()
        if ALLOWED_CLIENT_IDS and client_app_id not in ALLOWED_CLIENT_IDS:
            logger.warning("Rejected token: client app (azp) %s is not allow-listed", client_app_id)
            return None

        logger.info(
            "Authenticated call: oid=%s azp=%s scp=%s",
            claims.get("oid"),
            client_app_id,
            claims.get("scp"),
        )
        return access_token


auth = EntraOboTokenVerifier(
    jwks_uri=JWKS_URI,
    issuer=TOKEN_ISSUER,
    # v2 access tokens carry the bare client ID (GUID) as audience, not api://...
    audience=BACKEND_CLIENT_ID,
    required_scopes=[REQUIRED_SCOPE],
)

mcp = FastMCP(
    name="dummy-obo-mcp",
    instructions=(
        "Dummy MCP server behind Azure AI Gateway. Use whoami to see which signed-in "
        "user the gateway forwarded via On-Behalf-Of."
    ),
    auth=auth,
)

READ_ONLY = {"readOnlyHint": True, "openWorldHint": False}


@mcp.tool(annotations=READ_ONLY)
def whoami() -> dict[str, Any]:
    """Return the signed-in user's identity as seen by the MCP backend (from the OBO access token)."""
    token = get_access_token()
    claims = token.claims if token else {}
    expires = claims.get("exp")
    return {
        "name": claims.get("name"),
        "username": claims.get("preferred_username") or claims.get("upn"),
        "object_id": claims.get("oid"),
        "tenant_id": claims.get("tid"),
        "scopes": claims.get("scp"),
        "audience": claims.get("aud"),
        "issuer": claims.get("iss"),
        "client_app_id": claims.get("azp"),
        "token_version": claims.get("ver"),
        "token_expires_utc": (
            datetime.fromtimestamp(int(expires), tz=timezone.utc).isoformat() if expires else None
        ),
    }


@mcp.tool(annotations=READ_ONLY)
def echo(message: str) -> str:
    """Echo a message back, prefixed with the caller's display name."""
    token = get_access_token()
    name = (token.claims.get("name") if token else None) or "anonymous"
    return f"{name} said: {message}"


@mcp.tool(annotations=READ_ONLY)
def get_server_time() -> str:
    """Return the MCP backend's current UTC time (ISO 8601)."""
    return datetime.now(timezone.utc).isoformat()


@mcp.custom_route("/healthz", methods=["GET"])
async def healthz(_: Request) -> JSONResponse:
    return JSONResponse({"status": "ok"})


# Stateless JSON responses: no sticky sessions needed behind the gateway or when scaling out.
app = mcp.http_app(path="/mcp", stateless_http=True, json_response=True)


if __name__ == "__main__":
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8000")),
        proxy_headers=True,
        forwarded_allow_ips="*",
    )
