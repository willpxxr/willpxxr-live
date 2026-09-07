# WEP-0014 (ADR): Hermes agent via AI gateway with custom provider plugin

## Status

Accepted (2026-09-07)

## Context

We want a long-running autonomous agent in the de/hetzner cluster —
[Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research,
a self-improving Python agent with persistent memory, skills, and
messaging-gateway integration.

The LLM provider must be the in-cluster AI gateway
(`ai.internal.willpxxr.com`), not direct Synthetic — the gateway provides
model routing, accounting, and the ability to add custom model aliases via
`AIGatewayRoute` rules. However, the gateway's `SecurityPolicy` requires a
bearer JWT with `llm:use` scope and audience `https://ai.internal.willpxxr.com`
— designed for interactive clients (crush via oauth2c), not for an unattended
server workload.

Hermes's model provider plugin system (`plugins/model-providers/`) supports
`auth_type="api_key"` (static key), `oauth_external` (browser login →
`auth.json`), and `external_process` (subprocess) — but **not** M2M
`client_credentials` with automatic token refresh. Forking Hermes to add a
new auth type would carry merge burden across every upgrade.

## Decision

Use Hermes's `create_client` provider hook to handle Auth0 M2M token refresh
entirely in-process — no sidecar, no fork.

1. **Auth0 M2M client** (`terraform/auth0.tf`): a `non_interactive` client
   (`hermes_m2m`) with `client_credentials` grant, authorized for `llm:use`
   on the `ai_llm` resource server. Additional scopes `llm:auto`, `llm:small`,
   `llm:large` gate per-alias access. Credentials stored in 1Password
   (`hermes-m2m` in the `kubernetes` vault) and synced to the cluster via
   `ExternalSecret`.
2. **Custom provider plugin** (`apps/hermes/configmap-plugin.yaml`): a
   `ProviderProfile` subclass that overrides `create_client` to return an
   `openai.OpenAI` client backed by a custom `httpx` transport. The transport
   mints and caches an Auth0 M2M token (refreshing 60s before expiry) and
   injects it as the `Authorization: Bearer` header on every request. A
   `get_mcp_token()` helper mints tokens for the MCP gateway audience using the
   same M2M client. The plugin is mounted **read-only from a ConfigMap** at
   `/opt/data/plugins/model-providers/willpxxr-gateway/` — not in the PVC, so
   it's git-managed and can't drift.
3. **Hermes config** (`apps/hermes/configmap.yaml`): `model.provider:
   willpxxr-gateway`, `model.default: willpxxr:auto`. Custom model aliases
   `willpxxr:auto`, `willpxxr:text:small`, `willpxxr:text:large` map to the
   AI gateway routes. Staged via init container to the PVC (s6 config
   migrations apply to the copy).
4. **Custom model aliases** (`apps/ai-gateway-llm/ai-gateway-route-willpxxr.yaml`):
   three `AIGatewayRoute` rules (`willpxxr:auto` → `syn:small:text`,
   `willpxxr:text:small` → `syn:small:text`, `willpxxr:text:large` →
   `syn:large:text`) each with a per-scope `SecurityPolicy` enforcing
   `llm:auto`/`llm:small`/`llm:large` scopes respectively.
5. **MCP gateway integration** (`apps/hermes/configmap.yaml`): `mcp_servers.willpxxr-mcp`
   with `auth: oauth` (DCR — no static client_id/secret). Hermes auto-registers
   via Auth0 DCR on first connection; the token is persisted to
   `/opt/data/mcp-tokens/`. The MCP gateway fronts third-party MCP servers at
   `mcp.internal.willpxxr.com/mcp`, gated by `mcp:use` scope.
6. **Dashboard** (`apps/hermes/deployment.yaml`, `apps/hermes/httproute.yaml`):
   Hermes's built-in self-hosted OIDC provider (Auth0 PKCE native client
   `hermes_dashboard`) handles authentication — no Envoy SecurityPolicy layer.
   Exposed at `hermes.internal.willpxxr.com` via HTTPRoute, callback URL
   `https://hermes.internal.willpxxr.com/auth/callback`.
7. **Split-brain DNS** (`apps/kube-system/coredns-configmap.yaml`): CoreDNS
   `rewrite name` rules for `ai.internal.willpxr.com` and
   `mcp.internal.willpxxr.com` → Envoy gateway Service ClusterIP, so pods reach
   the data plane directly without Tailscale. The node's default resolver
   (Tailscale MagicDNS, `100.100.100.100`) handles all other `willpxxr.com`
   queries, including `auth.willpxxr.com` for Auth0 OIDC discovery and M2M
   token exchange.
8. **Network policies** (`apps/hermes/network-policy.yaml`): default-deny with
   same-namespace, DNS, AI gateway egress (port 10443 to envoy-gateway-system),
   Auth0 egress (port 443, `toEntities: world` — Auth0 is Cloudflare-fronted,
   IPs not enumerable), Discord egress (port 443, `toEntities: world`), and
   gateway ingress (port 9119 from envoy-gateway-system).
9. **Persistent storage** (`apps/hermes/deployment.yaml`): 10Gi PVC
   (`hcloud-volumes` StorageClass, provisioned by hcloud-csi) at `/opt/data`
   for Hermes memory, sessions, and MCP tokens. The init container stages
   config from ConfigMaps to the PVC before the main container starts.
10. **Discord** (`apps/hermes/externalsecret.yaml`, `apps/hermes/deployment.yaml`):
    Bot token from 1Password (`hermes-discord`), `DISCORD_ALLOWED_USERS`
    restricts to a single user. Bot connected as Marley#3516.

## Consequences

- Token refresh is in-process Python (httpx transport), not a separate
  sidecar — simpler deployment, but the plugin is Hermes-specific and an
  upstream change to the `create_client` hook contract could break it.
- The plugin code is git-managed via ConfigMap (read-only mount), not in the
  PVC — no drift between sessions.
- The Auth0 M2M client's credentials are in the same 1Password vault as the
  other cluster secrets, rotated via the same git-driven `ExternalSecret`
  pattern (6h refresh, force-sync for on-demand).
- The AI gateway's model routing and accounting cover Hermes's LLM calls;
  custom model aliases are `AIGatewayRoute` rules with per-scope SecurityPolicies,
  adjustable without touching Hermes config.
- MCP gateway access uses DCR (no static credentials to rotate), but the
  one-time `hermes mcp login willpxxr-mcp` paste-back flow is still needed
  (see "Not yet working" below).
- Dashboard auth is a single layer (built-in OIDC), not two (OIDC + Envoy
  SecurityPolicy) — simpler, but the dashboard must be reachable from the
  browser for the PKCE redirect to work.
- CoreDNS `forward willpxxr.com.` was originally added to bypass Tailscale
  MagicDNS (which doesn't resolve non-proxied Cloudflare DNS-only records like
  `auth.willpxxr.com`) but was removed after a typo (`willpxr` → `willpxxr`)
  caused the forward to query the wrong domain. Tailscale MagicDNS resolves
  `auth.willpxxr.com` correctly; the split-brain rewrites for
  `*.internal.willpxxr.com` remain.

## What's working

- **LLM inference**: Hermes → Auth0 M2M token → split-brain DNS → in-cluster
  Envoy → AI gateway → Synthetic → GLM model. End-to-end verified.
- **Model aliases**: `/model` picker shows `willpxxr:auto`, `willpxxr:text:small`,
  `willpxxr:text:large`. Per-scope SecurityPolicies enforce the correct scopes.
- **Discord**: Bot connected as Marley#3516, responds to allowed user.
- **Dashboard**: Built-in OIDC flow redirects to Auth0 login page and back;
  `auth.willpxxr.com` discovery resolves from inside the pod via Tailscale
  MagicDNS.
- **hcloud-csi**: First StorageClass on the cluster (`hcloud-volumes`),
  PVC provisioned and mounted.

## Not yet working

- **MCP gateway OAuth login**: The DCR client was auto-created
  (`tpc_9P1zy6JJhH96vnhWTzhE6T`) but the one-time `hermes mcp login
  willpxxr-mcp` paste-back flow has not been completed. The MCP server
  connection is parked with `PermissionError: [Errno 13] Permission denied:
  '/opt/data/mcp-tokens/willpxxr-mcp.json'` — the `/opt/data/mcp-tokens/`
  directory doesn't exist or has wrong ownership on the PVC. Needs:
  1. Create `/opt/data/mcp-tokens/` with correct permissions (writable by
     the Hermes process user).
  2. Run `hermes mcp login willpxxr-mcp` via `kubectl exec` to complete the
     OAuth paste-back flow.
- **Title generation**: `agent.auxiliary_client` falls back to Nous/OpenRouter
  for title generation, which fail with auth errors (no Nous auth, OpenRouter
  payment error). This is cosmetic (conversation titles) and doesn't affect
  agent functionality, but the warnings are noisy. Needs either: configure
  the auxiliary client to use `willpxxr-gateway`, or suppress the fallback
  chain.
- **Cilium FQDN egress policies**: Auth0 and Discord egress use
  `toEntities: world` on port 443 (IPs not enumerable). An attempt to use
  `toFQDNs` failed — Cilium's FQDN proxy wasn't intercepting DNS queries
  (FQDN cache empty). Reverted to `world:443`. If FQDN policies are desired,
  needs investigation into why the DNS proxy isn't intercepting (possibly
  related to Cilium's kube-proxy replacement mode + socket-LB).
- **Per-user MCP authorization**: Currently a single M2M client is used for
  all MCP gateway access. Per-user authorization (mapping dashboard OIDC
  identity to MCP gateway scopes) is deferred.
