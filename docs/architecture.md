# Flow: Microsoft 365 Copilot / Copilot Cowork → Azure AI Gateway → MCP server (as the user)

The user signs in once in Copilot. Every tool call then reaches the MCP backend with a token
that carries **the user's identity** but was issued **for the backend** and requested **by the
gateway's token exchange app**. No secrets sit in the gateway: it authenticates as the token
exchange app with its user-assigned managed identity (workload identity federation).

## 1. Runtime sequence (one tool call)

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant C as M365 Copilot / Copilot Cowork<br/>(federated connector)
    participant E as Microsoft Entra ID
    participant G as Azure AI Gateway<br/>MCP server "dummy-mcp"
    participant MI as Gateway user-assigned<br/>managed identity
    participant EA as Container Apps<br/>built-in auth (Easy Auth)
    participant B as MCP server<br/>(FastMCP container)

    rect rgb(235, 245, 255)
    Note over U,E: A. Sign-in. Once per user, refreshed silently with offline_access.
    U->>C: Ask something that needs a tool
    C->>E: Authorization code + PKCE<br/>client_id = App A (Copilot connector)<br/>scope = https://ai.gateway.azure.com/Data.All offline_access
    E-->>U: Sign-in page (admin consent already granted, so no consent prompt)
    E-->>C: T1 = user token<br/>aud = AI Gateway app (18550318-…), scp = Data.All, azp = App A
    end

    rect rgb(240, 250, 240)
    Note over C,G: B. MCP over Streamable HTTP (initialize, tools/list, tools/call)
    C->>G: POST https://{gateway host}/default/toolservers/dummy-mcp/mcp<br/>Authorization: Bearer T1
    G->>G: Validate T1 (tenant issuer, aud, Data.All)<br/>Azure RBAC: is the user "AI Gateway Tools User" on this MCP server?
    end

    rect rgb(255, 245, 230)
    Note over G,E: C. On-Behalf-Of exchange. Secretless: no client secret anywhere.
    G->>E: (1) Exchange T1 for a token to the token exchange app<br/>scope = api://{App B}/FederationApp.Access<br/>(works because the AI Gateway app is pre-authorized on App B)
    E-->>G: T1' (aud = App B, still the user)
    G->>MI: (2) Get managed identity token for api://AzureADTokenExchange
    MI-->>G: MI assertion (sub = MI principal ID)
    G->>E: (3) OBO as App B<br/>client_id = App B, client_assertion = MI assertion<br/>assertion = T1', scope = api://{App C}/user_impersonation
    E->>E: Federated credential on App B matches issuer/subject/audience?<br/>Admin consent App B → App C user_impersonation present?
    E-->>G: T2 = backend token<br/>aud = App C (GUID), scp = user_impersonation, azp = App B, oid = user
    end

    rect rgb(245, 240, 255)
    Note over G,B: D. Backend call, validated twice
    G->>EA: Forward MCP request<br/>Authorization: Bearer T2
    EA->>EA: Layer 1, App C registration: v2 issuer,<br/>aud = App C, client app = App B, otherwise 401
    EA->>B: Pass the request on, token still in the Authorization header
    B->>B: Layer 2, server.py re-validates T2 against the tenant JWKS:<br/>aud = App C, scp has user_impersonation, azp = App B
    B-->>G: Tool result (e.g. whoami: the user's oid, name)
    G-->>C: Result. Tools are namespaced: dummy_whoami, dummy_echo, ...
    C-->>U: Answer
    end
```

Step C(1) happens inside the gateway and isn't observable from outside. It's the hop implied by
the required configuration: the gateway's first-party app must be pre-authorized for
`FederationApp.Access` on the token exchange app. Everything else was verified end to end with
`scripts/test-obo.py`. The backend received the caller's `oid`, with `aud` = App C and
`azp` = App B.

## 2. Tokens along the way

| Token | Issued to (azp) | Audience (aud) | Scope (scp) | Identity | Who validates it |
| --- | --- | --- | --- | --- | --- |
| **T1** | App A (Copilot connector) | `18550318-e177-4205-a743-6816d6fcdc3f` (AI Gateway) | `Data.All` | user | AI Gateway, then Azure RBAC |
| **T1'** | AI Gateway app | App B (token exchange) | `FederationApp.Access` | user | Entra (OBO input) |
| MI assertion | Gateway managed identity | `api://AzureADTokenExchange` | n/a | managed identity | Entra (federated credential on App B) |
| **T2** | App B (token exchange) | App C client ID (v2 tokens use the bare GUID) | `user_impersonation` | user | Easy Auth, then `server.py` |

## 3. Trust relationships created by Terraform

```mermaid
flowchart TB
    USER(("Copilot users"))
    COP["M365 Copilot / Copilot Cowork<br/>federated connector"]

    subgraph ENTRA["Microsoft Entra ID (azuread provider)"]
        direction LR
        A["App A: Copilot connector<br/>client secret + Teams redirect URI"]
        AIGW["AI Gateway Dataplane<br/>first-party app 18550318-…<br/>scope Data.All"]
        B["App B: token exchange<br/>scope FederationApp.Access"]
        FIC["Federated credential on App B<br/>subject = MI principal ID<br/>audience = api://AzureADTokenExchange"]
        C["App C: MCP backend API<br/>scope user_impersonation<br/>v2 access tokens"]
        A -- "Data.All<br/>admin consent" --> AIGW
        AIGW -- "pre-authorized for<br/>FederationApp.Access" --> B
        FIC -- "credential of" --> B
        B -- "user_impersonation<br/>admin consent + pre-authorized" --> C
    end

    subgraph AZURE["Azure subscription (azurerm + azapi providers)"]
        direction LR
        GW["AI Gateway: MCP server dummy-mcp<br/>backend auth = OAuth2 token exchange (OBO)"]
        MI["User-assigned<br/>managed identity"]
        ACA["Container App: FastMCP server<br/>Easy Auth (App C) + in-code checks"]
        ACR["Container Registry"]
        GW -- "attached identity" --> MI
        GW -- "MCP request + T2" --> ACA
        ACR -- "image pull (AcrPull)" --> ACA
    end

    USER --> COP
    COP -- "signs in with App A,<br/>sends T1" --> GW
    USER -. "role: AI Gateway Tools User<br/>on the MCP server" .-> GW
    MI -. "federated trust" .-> FIC
    C -. "protects" .-> ACA
```

## 4. Why each piece exists

| Piece | Without it |
| --- | --- |
| AI Gateway Dataplane service principal in the tenant | No tenant can issue `Data.All` tokens; Copilot sign-in fails. |
| App A delegated `Data.All` + admin consent | Users get consent prompts, or a "needs admin approval" block, in Copilot. |
| Runtime role **AI Gateway Tools User** | Gateway returns 403. Owner and Contributor do not grant tool invocation. |
| Pre-authorization of `18550318-…` on App B | The gateway can't obtain T1', so OBO fails. |
| Federated credential (subject = MI **principal** ID) | App B can't authenticate; OBO fails. |
| Toolserver `appCredential.clientId` = MI **client** ID | The gateway picks the wrong identity. |
| App B → App C admin consent | OBO fails with a consent error (`AADSTS65001`), and the gateway returns 401. |
| Explicit backend scope (not `/.default`) | The gateway rejects the configuration. |
| App C `requested_access_token_version = 2` | T2 is a v1 token (`sts.windows.net` issuer, `api://` audience), so the backend rejects it. |
| Container Apps Easy Auth with App C | Invalid tokens would reach the container, leaving the in-code checks as the only gate. |
| Backend `azp` allow-list (Easy Auth `allowedApplications` + code) | Any app with a consented token for App C could call the backend directly. |
| Gateway MCP versions ⊆ backend versions | M365 Copilot proposes `2025-11-25`; mismatches show up as 502 or `-32603` on `tools/list`. |
