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
   point.** (Amended 2026-09-01: the injection point moved *out of* the data
   path -- Envoy's `extAuth` check calls the vault's `/authz` per
   `tools/call`, the vault answers with the bearer header, and Envoy injects
   it upstream (`headersToBackend`), so MCP traffic goes
   client -> gateway -> upstream directly; the backend is named `linear`,
   making the tool prefix the provider key the vault resolves on. The
   vault's proxy listener remains as a fallback but Linear no longer rides
   it.) New app `apps/mcp-token-vault` (namespace `mcp-token-vault`, per
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

3. **The vault talks to Supabase over Postgres**, not the REST/PostgREST
   surface: fewer auth surfaces, no Supabase Auth in the data path, standard
   SQL for the refresh loop. The connection string and encryption key are the
   vault's only secrets, delivered via ExternalSecret
   (`mcp-token-vault/credentials/db_url`, `.../encryption_key`). The vault
   uses a **dedicated least-privilege role** (created by the schema migration,
   not the dashboard's `postgres` role) with `sslmode=require` minimum.
   **Connection path is an IPv4 question**: Supabase's direct endpoint is
   IPv6-only without the paid IPv4 add-on (verified against their connecting
   docs, 2026-08-31); Phase 0 must verify real IPv6 egress from the pods
   (node has v6 != pod route does) and otherwise use the Supavisor
   session-mode pooler, which is IPv4 on every tier.
   **The Supabase project itself is Terraform-managed** (`supabase.tf`):
   the official `supabase/supabase` provider (v1.x, verified resource surface:
   project/settings/apikey/... + a pooler data source) creates the project and
   resolves the session-pooler URL; the db_url and encryption key are written
   into the 1Password `kubernetes` vault by `onepassword_item` (writer of
   record, betterstack.tf pattern). The provider only authenticates with a
   static Management-API access token -- no OIDC federation surface, unlike
   the Tailscale TFC workload-identity path. Two things stay manual: the
   least-privilege role bootstrap SQL (`scripts/0000-bootstrap-role.sql`, the
   provider has no SQL-execution resource) and the schema migrations (applied
   by the vault on boot, in-repo under `migrations/`).

4. **Credential bootstrap is human-in-the-loop, once per provider.** A
   headless vault can never perform the initial OAuth `authorization_code`
   dance (no provider offers client-credentials for this). The connect flow
   runs through an **out-of-band browser UI**: `tokens.internal.willpxxr.com`
   (HTTPRoute to the vault's oauth listener, Auth0 SecurityPolicy gating it
   with the shared `envoy-gateway-oidc` client + a `token_vault:use` scope)
   lists configured providers and links each to the vault's
   `/oauth/<provider>/start`, which runs the PKCE authorization and stores
   the result. The provider's authorization-code callback lands on a
   separate **unpolicied** `/cb/` HTTPRoute -- a provider redirect cannot
   perform Auth0 browser login mid-flow -- and is protected by the
   single-use PKCE `state` table instead. The UI exists because the
   in-band alternative is a dead end: MCP `elicitation/create` requests
   from behind the AI Gateway proxy get swallowed (the elicitation error
   never reaches the client), so the connect URL must be a stable address
   the user knows, not a payload relayed through the proxy. This mirrors
   how the MCP spec itself handles OAuth: the client opens a browser out
   of band. A cluster-internal `/bootstrap` admin endpoint (port-forward)
   remains for scripting. From then on the vault owns the token lifecycle:
   refresh ahead of `expires_at`, on 401 -> refresh -> retry once.

5. **Sequencing: Linear can land before the vault exists.** A Linear API key
   works today through the unchanged `securityPolicy.apiKey` + ESO path if a
   quick integration is wanted; the vault replaces it when OAuth-scoped
   Linear access or the first OAuth-only provider arrives. The vault must
   therefore be purely additive -- no changes to working backends.

## Plan

- **Phase 0 -- groundwork**: Terraform-created Supabase project (`supabase.tf`;
  needs `var.supabase_token` + `var.supabase_organization_id` in the TFC
  workspace); `migrations/0001_init.sql`
  (`credentials(id, provider, principal, kind, access_token_enc,
  refresh_token_enc, expires_at, scopes, rotated_at, created_at)`); role
  bootstrap is folded into the vault itself: Terraform writes an `admin_url`
  (built-in postgres role) alongside `db_url` into the 1Password item, and
  the vault reconciles its own least-privilege role/password against db_url
  on every startup (idempotent, self-heals rotation); `scripts/0000-bootstrap-role.sql`
  remains only as a manual break-glass reference; 1Password
  items written by Terraform (`mcp-token-vault/credentials/db_url` +
  `encryption_key` + `admin_url`) and by hand
  (`linear-mcp-oauth/credentials/client_id` +
  `client_secret`, placeholders until the Linear OAuth app exists); network
  policy: `world:443` egress for Supabase and per-upstream MCP hosts, each
  with a why-description.
- **Phase 1 -- the vault**: `apps/mcp-token-vault` (Rust: axum + reqwest,
  streaming proxy, Postgres via `sqlx`), Deployment + Service + CNP
  (default-deny, allow-dns, allow-kube-apiserver not needed) + ExternalSecrets
  + admin endpoint bound to the in-cluster interface only.
- **Phase 2 -- first backend**: Linear OAuth app (minimal scopes); one-time
  authorization via the credential UI (`tokens.internal.willpxxr.com`,
  decision 4); `Backend` + `BackendTLSPolicy` for the vault in
  `apps/ai-gateway-mcp` (or FQDN-only, in-cluster) and the MCPRoute
  backendRef pointed at it.
- **Phase 3 -- cutover/cleanup**: retire the demo `kiwi` backend once a real
  one is proven; decide whether Better Stack moves behind the vault (probably
  not -- static is fine).

## Deliberately deferred

- **Federated/workload identity for DB auth.** Supabase's Postgres accepts
  only username/password (SCRAM) on the wire -- its SSO is dashboard-scoped
  and its Auth0 integration mints end-user Data API JWTs, neither authenticates
  a database role (verified 2026-08-31). There is no IRSA-style surface to
  federate a k8s service-account token into. Vault-style dynamic per-lease DB
  credentials were considered and deferred: a credential broker is another
  service to run and still bootstraps from a static admin credential -- not
  justified for one single-tenant database whose rows are ciphertext anyway.
  Revisit if Supabase ships managed OAuth DB auth (Postgres 18 adds native
  OAuth client support upstream).
- **Migrate the injection path to AIGW-native RFC 8693 token exchange.**
  Upstream proposal 010 (envoyproxy/ai-gateway PR #2052, merged 2026-06 as a
  docs proposal; not in v1.1.0's CRD surface) defines `tokenExchange` as a
  per-backend MCP upstream auth: the gateway exchanges the validated client
  JWT at an external STS for a backend-scoped token. When a release we run
  implements it, the vault's proxy listener retires: the vault exposes an
  RFC 8693 token endpoint (validating the Auth0 JWT via JWKS, mcp:use scope,
  aud pinning) and remains the credential store + refresh engine -- the part
  the proposal explicitly delegates to an external STS.

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
is disposable (re-bootstrap credentials via the credential UI or the
`/bootstrap` admin endpoint).
