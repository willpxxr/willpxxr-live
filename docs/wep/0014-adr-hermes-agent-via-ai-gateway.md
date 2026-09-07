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
   with `client_credentials` grant, authorized for `llm:use` on the `ai_llm`
   resource server. Credentials stored in 1Password (`hermes-m2m` in the
   `kubernetes` vault) and synced to the cluster via `ExternalSecret`.
2. **Custom provider plugin** (`apps/hermes/configmap-plugin.yaml`): a
   `ProviderProfile` subclass that overrides `create_client` to return an
   `openai.OpenAI` client backed by a custom `httpx` transport. The transport
   mints and caches an Auth0 M2M token (refreshing 60s before expiry) and
   injects it as the `Authorization: Bearer` header on every request. The
   plugin is mounted **read-only from a ConfigMap** at
   `/opt/data/plugins/model-providers/willpxxr-gateway/` — not in the PVC, so
   it's git-managed and can't drift.
3. **Hermes config** (`apps/hermes/configmap.yaml`): `model.provider:
   willpxxr-gateway`, `model.default: hf:zai-org/GLM-5.3-Flash`. Staged via
   init container to the PVC (s6 config migrations apply to the copy).
4. **Model**: `hf:zai-org/GLM-5.3-Flash` through the gateway's existing
   `AIGatewayRoute` (matches `^(syn|hf):.+$`). Custom aliases can be added
   later via new `AIGatewayRoute` rules with `modelNameOverride`.

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
  custom model aliases can be added as `AIGatewayRoute` rules without
  touching Hermes config.
