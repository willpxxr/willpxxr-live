# mcp-token-vault

Credential vault for `ai-gateway-mcp` (WEP-0006 in willpxxr-live): stores
third-party MCP credentials (envelope-encrypted) in Supabase Postgres,
refreshes OAuth tokens, and proxies MCP traffic to upstream servers with the
fresh bearer injected.

- Storage: Supabase Postgres (direct, dedicated least-privilege role). Token
  columns are XChaCha20-Poly1305 ciphertext; the master key never leaves the
  cluster (1Password → ESO → env).
- Admin API (`/bootstrap`, `/healthz`): cluster-internal only — no Service
  exposes it; use `kubectl port-forward`. Optional `ADMIN_TOKEN` bearer.
- Credential UI: browser-facing oauth listener (9091) on
  `tokens.internal.willpxxr.com` (HTTPRoute + Auth0 SecurityPolicy, see
  `gitops/.../apps/mcp-token-vault/httproute-ui.yaml`). `GET /` lists
  providers with stored-credential status; `/oauth/<provider>/start` runs
  the PKCE authorization. The provider callback lives under `/cb/` on an
  unpolicied route (a provider redirect can't do Auth0 login mid-flow);
  it's protected by the single-use PKCE `state` table. The UI exists
  because MCP in-band elicitations are swallowed by the AI Gateway proxy
  (WEP-0006 decision 4) — the connect URL must be a stable address, not a
  payload relayed through the proxy.
- Proxy: one listener (`PROXY_PORT`, default 8081), path-dispatched by the
  first path segment (`/<provider>/...` -- the MCPRoute backendRef path);
  forwards to the upstream MCP server with
  `Authorization: Bearer <access token>`, refreshing on 401 and ahead of
  expiry. Providers are enumerated by their `PROVIDER_<NAME>_UPSTREAM_URL`
  env; adding one is env config + a new MCPRoute backendRef, no new ports.

## Config (env)

| Var | Meaning |
| --- | --- |
| `DATABASE_URL` | Postgres connection string (ESO-delivered) |
| `VAULT_ENCRYPTION_KEY` | base64 32-byte master key (ESO-delivered) |
| `ADMIN_PORT` | admin listener, default `9090` (never exposed via Service) |
| `OAUTH_PORT` | browser-facing credential-UI listener, default `9091` |
| `ELICITATION_BASE_URL` | public Gateway hostname serving `/` and `/oauth/*` (`tokens.internal.willpxxr.com`) |
| `ADMIN_TOKEN` | optional bearer required on `/bootstrap` |
| `PROVIDER_<NAME>_UPSTREAM_URL` | upstream MCP server base URL; also enumerates the provider |
| `PROVIDER_<NAME>_UPSTREAM_URL` | upstream MCP server base URL |
| `PROVIDER_<NAME>_TOKEN_URL` | OAuth token endpoint (enables refresh) |
| `PROVIDER_<NAME>_AUTHORIZE_URL` | OAuth authorize endpoint (enables elicitation UX) |
| `PROVIDER_<NAME>_REDIRECT_URI` | OAuth redirect URI (must match the provider app) |
| `PROVIDER_<NAME>_SCOPES` | optional space-separated scopes |
| `PROVIDER_<NAME>_CLIENT_ID` / `_CLIENT_SECRET` | OAuth client for refresh + elicitation |

## Deploy order

Everything below is GitOps/Terraform-driven; there is no manual DB step:

1. `supabase.tf` (in willpxxr-live) creates the Supabase project and writes
   the `mcp-token-vault` 1Password item: `db_url` (least-privilege role via
   the session pooler), `encryption_key`, `admin_url` (built-in postgres
   role), `role_password`.
2. ExternalSecrets sync them (refreshInterval 6h) → `apps/mcp-token-vault`.
3. On startup the vault bootstraps its own role using `ADMIN_DATABASE_URL`
   (create-if-missing + password reconciled to `db_url`), then runs its
   schema migrations, then serves traffic.
4. Per-provider credentials arrive via the credential UI
   (`https://tokens.internal.willpxxr.com`) or the cluster-internal
   `/bootstrap` API (`kubectl port-forward <pod> 9090:9090`).

## Dev

```sh
cargo test
cargo run            # needs env above; see docker-compose-less local flow
docker build -t mcp-token-vault .
```

Cache-check: warm-build probe.
