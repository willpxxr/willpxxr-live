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
- Proxy: one listener per provider (`PROVIDER_<NAME>_LISTEN_PORT`); forwards
  to the upstream MCP server with `Authorization: Bearer <access token>`,
  refreshing on 401 and ahead of expiry.

## Config (env)

| Var | Meaning |
| --- | --- |
| `DATABASE_URL` | Postgres connection string (ESO-delivered) |
| `VAULT_ENCRYPTION_KEY` | base64 32-byte master key (ESO-delivered) |
| `ADMIN_PORT` | admin listener, default `9090` (never exposed via Service) |
| `OAUTH_PORT` | browser-facing elicitation listener, default `9091` |
| `ELICITATION_BASE_URL` | public Gateway hostname serving `/oauth/*` |
| `ADMIN_TOKEN` | optional bearer required on `/bootstrap` |
| `PROVIDER_<NAME>_LISTEN_PORT` | proxy listener for provider `<name>` |
| `PROVIDER_<NAME>_UPSTREAM_URL` | upstream MCP server base URL |
| `PROVIDER_<NAME>_TOKEN_URL` | OAuth token endpoint (enables refresh) |
| `PROVIDER_<NAME>_AUTHORIZE_URL` | OAuth authorize endpoint (enables elicitation UX) |
| `PROVIDER_<NAME>_REDIRECT_URI` | OAuth redirect URI (must match the provider app) |
| `PROVIDER_<NAME>_SCOPES` | optional space-separated scopes |
| `PROVIDER_<NAME>_CLIENT_ID` / `_CLIENT_SECRET` | OAuth client for refresh + elicitation |

## Deploy order

1. Supabase project → run `scripts/0000-bootstrap-role.sql` in the SQL editor
   → store `postgresql://token_vault:<pw>@<host>:5432/postgres` in 1Password
   as `mcp-token-vault/credentials/db_url`.
2. Generate a 32-byte key (`openssl rand -base64 32`) → 1Password as
   `mcp-token-vault/credentials/encryption_key`.
3. ExternalSecrets for both (refreshInterval 6h) → `apps/mcp-token-vault`.
4. Bootstrap a credential:
   `kubectl port-forward <pod> 9090:9090` then
   `curl -X POST localhost:9090/bootstrap -d '{"provider":"linear","kind":"oauth","refresh_token":"..."}'`
   (one-time human OAuth dance per WEP-0006 / `scripts/` helper in
   willpxxr-live).

## Dev

```sh
cargo test
cargo run            # needs env above; see docker-compose-less local flow
docker build -t mcp-token-vault .
```
