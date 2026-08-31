# WEP-0006 (RFC): Token vault for `ai-gateway-mcp` third-party credentials (Supabase-backed)

## Status

Proposed (2026-08-31) -- awaits review; phases ship as separate applies (see
Plan).

## Context

`apps/ai-gateway-mcp` fronts third-party MCP servers through Envoy AI
Gateway: an `MCPRoute` at `https://mcp.internal.willpxxr.com/mcp` validates
client Auth0 bearers (`mcp:use`, pre-registered `ai_gateway_mcp` client, same
pattern as the LLM gateway) and routes to per-backend refs. Upstream
authentication today is one mechanism: `MCPRouteBackendRef.securityPolicy.apiKey`,
which injects a **static** value from a k8s Secret (ESO-synced from 1Password
-- the `betterstack-mcp` pattern).

That mechanism -- and ESO generally -- is structurally read-only and static.
It cannot:

- **acquire** an OAuth grant (several MCP servers are OAuth-only; some
  providers offer no API-key escape hatch),
- **refresh** access tokens and **write back** rotated refresh tokens (ESO
  syncs 1Password -> cluster, never pod -> store),
- hold **vault state**: expiry timestamps, scopes, per-principal rows.

The concrete driver is Linear: it supports a static API key (onboardable
today via the existing path), but that key is personal-scoped
(full-account or read-only), and the general case -- OAuth-only providers,
per-principal tokens -- has no home in the current design. A token vault is
the missing component: something that stores third-party credentials, keeps
them fresh, and vends/injects them for the gateway.

The user chose **Supabase** as the vault's storage. This WEP records why that
is sound despite this repo's "secrets live in 1Password/ESO" rule, and where
the boundary sits.

## Decision

1. **The vault is a separate in-cluster service, and it is the injection
   point.** New app `apps/mcp-token-vault` (namespace `mcp-token-vault`, per
   the WEP-0005 lesson: never share a namespace across ArgoCD apps). For
   OAuth-needing backends, the MCPRoute `Backend` points at the vault's
   in-cluster FQDN (the proven `kagent-tools` backend pattern: Backend object
   with `endpoints.fqdn`, no BackendTLSPolicy -- TLS to upstream is the
   vault's job as an HTTP client). The vault proxies the MCP stream
   (streamable HTTP/SSE pass-through, no buffering) to the real upstream,
   injecting `Authorization: Bearer <fresh access token>`. This needs **no
   upstream CRD changes**: MCPRoute's per-backend static mechanism is only
   bypassed for these backends by pointing them at the vault instead.
   Static-key backends (Better Stack) stay exactly as they are.

2. **Supabase Postgres is the vault's state store; it never holds plaintext
   tokens.** A vault needs a database-shaped store (write-back of rotated
   refresh tokens, expiry tracking, one row per provider+principal) -- that
   is the one thing the 1Password/ESO pattern cannot be stretched into, so
   the "app DB is the wrong home for secrets" principle is refined rather
   than violated: token columns are stored **envelope-encrypted**
   (XChaCha20-Poly1305) under a master key whose only source of truth is
   1Password (`mcp-token-vault/credentials/encryption_key` -> ESO). A
   compromised Supabase project yields ciphertext only.

3. **The vault talks to Supabase over direct Postgres**, not the REST/PostgREST
   surface: fewer auth surfaces, no Supabase Auth in the data path, standard
   SQL for the refresh loop. The connection string and encryption key are the
   vault's only secrets, delivered via ExternalSecret
   (`mcp-token-vault/credentials/db_url`, `.../encryption_key`). The Supabase
   project itself is dashboard-created (no usable Terraform provider); schema
   ships as versioned SQL migrations in-repo, applied by the vault on boot.

4. **Credential bootstrap is human-in-the-loop, once per provider.** A
   headless vault can never perform the initial OAuth `authorization_code`
   dance (no provider offers client-credentials for this). A `scripts/`
   helper (pattern: `scripts/gateway-login`) drives PKCE authorization in a
   browser and POSTs the resulting refresh token to the vault's admin
   endpoint -- which is **cluster-internal only** (no Ingress/HTTPRoute; the
   MCPRoute's Auth0 policy already gates all client traffic). From then on
   the vault owns the token lifecycle: refresh ahead of `expires_at`, on 401
   -> refresh -> retry once.

5. **Sequencing: Linear can land before the vault exists.** A Linear API key
   works today through the unchanged `securityPolicy.apiKey` + ESO path if a
   quick integration is wanted; the vault replaces it when OAuth-scoped
   Linear access or the first OAuth-only provider arrives. The vault must
   therefore be purely additive -- no changes to working backends.

## Plan

- **Phase 0 -- groundwork**: Supabase project; `migrations/0001_init.sql`
  (`credentials(id, provider, principal, kind, access_token_enc,
  refresh_token_enc, expires_at, scopes, rotated_at, created_at)`); 1Password
  items (placeholder + hand-paste, the `synthetic.tf` pattern -- here hand
  only, no Terraform item resource is warranted); network policy: `world:443`
  egress for `<project>.supabase.co` and per-upstream MCP hosts, each with a
  why-description.
- **Phase 1 -- the vault**: `apps/mcp-token-vault` (Rust: axum + reqwest,
  streaming proxy, Postgres via `sqlx`), Deployment + Service + CNP
  (default-deny, allow-dns, allow-kube-apiserver not needed) + ExternalSecrets
  + admin endpoint bound to the in-cluster interface only.
- **Phase 2 -- first backend**: Linear OAuth app (minimal scopes); one-time
  authorization via the script helper; `Backend` + `BackendTLSPolicy` for the
  vault in `apps/ai-gateway-mcp` (or FQDN-only, in-cluster) and the MCPRoute
  backendRef pointed at it.
- **Phase 3 -- cutover/cleanup**: retire the demo `kiwi` backend once a real
  one is proven; decide whether Better Stack moves behind the vault (probably
  not -- static is fine).

## Risks

- **New inline hop** for vault-backed backends (availability + latency).
  Mitigation: per-backend opt-in; any backend can fall back to a static-key
  Backend by editing one ref.
- **Third-party token material in a shared SaaS Postgres.** Mitigation:
  envelope encryption (decision 2); Supabase compromise != token compromise;
  blast radius is third-party app access, not cluster secrets.
- **Supabase availability** gates vault-backed backends only, not the gateway
  as a whole (static backends are unaffected).
- **MCP streaming through a proxy**: streamable HTTP/SSE must pass through
  unbuffered; covered by explicit streaming tests in Phase 1.

## Rollback

Per-backend: point the MCPRoute backendRef back at a direct `Backend`
(static key via `securityPolicy.apiKey`, ESO) -- one manifest diff, no
cluster state to unwind. The vault app prunes independently. Supabase data
is disposable (re-bootstrap credentials via the script helper).
