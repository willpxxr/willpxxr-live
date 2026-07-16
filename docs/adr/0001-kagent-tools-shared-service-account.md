# 0001: kagent-tools MCP server -- shared read-only ServiceAccount, defer per-caller OBO token exchange

## Status

Accepted (2026-07-16)

## Context

We're adding `kagent-tools` (github.com/kagent-dev/tools -- a Go MCP server
bundling kubectl/Helm/Cilium toolsets) as a new backend behind the
`ai-gateway-mcp` MCPRoute, alongside the existing `kiwi`/`betterstack`
backends. The ideal design is per-caller attribution: bind Kubernetes RBAC to
the caller's own Auth0 identity, and have the gateway exchange the caller's
`mcp:use`-scoped MCP token for a Kubernetes-API-scoped token per request
(OAuth 2.0 Token Exchange, RFC 8693 -- "On-Behalf-Of"), rather than granting
one shared identity standing permissions.

We investigated what that would take:

- **The Kubernetes API server doesn't trust any OIDC IdP today** (`hetzner.tf`
  / `packer/talos/talos.pkr.hcl` have no `--oidc-*` apiserver flags). Adding
  this is a control-plane change to the live cluster, not just an app-layer
  config.
- **Envoy Gateway / Envoy AI Gateway have no native token-exchange/OBO
  mechanism** (confirmed via the live CRD schemas, not docs):
  `BackendSecurityPolicy` only injects static credentials; `SecurityPolicy.oidc`
  and `MCPRoute.securityPolicy.oauth` are inbound-only (authenticate the
  caller), not outbound token minting.
- **`EnvoyExtensionPolicy.spec.dynamicModule`** (a real, installed CRD) can
  load a Go-compiled Envoy filter, and
  [tetratelabs/built-on-envoy's token-exchange extension](https://github.com/tetratelabs/built-on-envoy/tree/main/extensions/composer/token-exchange)
  implements RFC 8693 this way. But its `config.schema.json` requires
  `client_secret` as a plain string (`additionalProperties: false`, no
  secretRef, no file-path option, no env-var expansion in `config.go`) -- the
  secret would have to live in the CRD as plaintext, conflicting with this
  repo's "secrets only via 1Password `ExternalSecret`" convention. Also
  unverified: whether the pinned `envoy-gateway` chart (`1.8.2`) bundles an
  Envoy proxy new enough for the module's stated 1.38.0-1.39.0 requirement.
- **agentgateway** (agentgateway.dev) is a separate proxy + Kubernetes
  controller with a native `backendAuth.oauthTokenExchange` policy (RFC 8693
  against generic OIDC IdPs, Auth0 included) that would run *alongside* Envoy
  Gateway as a second data plane. Not yet evaluated for secret handling.
- **Upstream tracking issue**:
  [envoyproxy/ai-gateway#2036](https://github.com/envoyproxy/ai-gateway/issues/2036)
  proposes adding native RFC 8693 support directly to `MCPRoute`. Open, one
  maintainer comment floating the same built-on-envoy module as a possible
  implementation. If this lands, it replaces the dynamic-module/agentgateway
  detour with a first-class field -- worth checking before investing further
  in either workaround.

None of this is a quick add to the `kagent-tools` deploy in front of us; it's
a separate project spanning the Talos API server config, a new Auth0 resource
server, and either a new gateway component (agentgateway) or a
not-fully-clean workaround (built-on-envoy's dynamic module).

## Decision

Deploy `kagent-tools` now with a single shared ServiceAccount, scoped as
tightly as the chart allows:

- `rbac.readOnly: true` -- `get`/`list`/`watch` only, not the chart's default
  (cluster-admin-equivalent).
- `tools.args: ["--read-only"]` -- disables every mutating/exec-capable tool
  at the application layer (`k8s_execute_command`, `k8s_apply_manifest`,
  `k8s_delete_resource`, Cilium's install/upgrade/endpoint-mutation tools,
  `utils`' `shell` tool), confirmed by reading the upstream Go source rather
  than trusting the flag's description.
- A separate, narrowly-scoped `kube-system` `Role` (not a cluster-wide grant)
  for `pods/exec`, accepted as an unavoidable requirement of Cilium's
  "read-only" debug tools, which shell out to `cilium-dbg` inside the agent
  pod because Cilium has no separate read-only debug API.
- `tools.k8s.tokenPassthrough: false` -- uses the ServiceAccount, not a
  passed-through caller token (there's no caller-scoped token to pass through
  yet anyway).

Access to the MCP endpoint overall stays gated by the existing Auth0
`mcp:use` scope check at the `MCPRoute` level, same as `kiwi`/`betterstack`.

## Consequences

- All callers holding a valid `mcp:use` token share one Kubernetes identity;
  there's no per-user audit trail inside the cluster for what `kagent-tools`
  did (same limitation the LLM gateway's `BackendSecurityPolicy` static-key
  backends already have, per
  [envoyproxy/ai-gateway#2036](https://github.com/envoyproxy/ai-gateway/issues/2036)'s
  own framing of this exact problem).
- The `pods/exec` grant into `kube-system`, while namespace-scoped, is a real
  elevated permission relative to everything else this ServiceAccount holds --
  RBAC can't restrict *which* command runs once exec is granted, only that
  the app code chooses to run `cilium-dbg`.
- Revisit this ADR when either envoyproxy/ai-gateway#2036 lands, or when the
  Talos OIDC + Auth0 resource-server + token-exchange work gets scoped as its
  own project. At that point `tools.k8s.tokenPassthrough` flips to `true` and
  this shared ServiceAccount's RBAC should shrink to near-nothing (or be
  removed entirely in favor of per-identity bindings).
