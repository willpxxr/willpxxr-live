# WEP-0007 (ADR): MCP upstream credential injection -- vault proxy fallback, defer Envoy-side injection until upstream support

## Status

Accepted (2026-09-01)

## Context

`ai-gateway-mcp` needs to attach third-party upstream credentials (Linear
first) to MCP calls routed through the gateway. The ideal design: Envoy
attaches the credential itself at the backend hop -- no proxy in the MCP
data path -- and eventually does so **per caller** (multi-user: each
Auth0 principal gets their own upstream grant, stored per-principal in the
WEP-0006 vault).

We investigated every injection mechanism Envoy AI Gateway v1.1.0 offers
(latest release; verified against the live cluster's CRDs and upstream
`main`, 2026-09-01):

- **Route-level `MCPRoute.securityPolicy.extAuth`** fires only on
  client-facing requests. The gateway's own per-backend fan-out (the
  `initialize`/`tools/list` calls it originates to each MCP server) never
  passes the filter: during a `tools/list`, the vault saw exactly the three
  client-side checks and zero fan-out checks, while Linear answered the
  unauthenticated fan-out with 401s. Also, `includeRouteMetadata` surfaced
  no route-identifying headers in the check, so even client-side checks
  can't select a provider for methods that have no tool prefix.
- **`MCPRoute.backendRefs[].securityPolicy`** (`MCPBackendSecurityPolicy`)
  is static-key only: `apiKey` with `header|inline|queryParam|secretRef`.
  No `credentialOverride` -- confirmed against the live CRD schema and
  upstream `main` (`api/v1beta1/mcp_route.go`), not just the installed
  version.
- **`credentialOverride` (envoyproxy/ai-gateway PR #2253, closes #2216)**
  is real and shipped in v1.1.0 -- but on `BackendSecurityPolicy`, which
  targets `AIServiceBackend`/`InferencePool` (LLM routes only). It cannot
  attach to MCPRoute backends. Even if it could, the
  `envoy.filters.http.ext_authz` dynamic-metadata namespace it reads is
  empty on fan-out streams, since those never traverse the ext_authz
  filter (first bullet).
- **Separately**, MCP in-band elicitation (`elicitation/create`) is a dead
  end for the connect UX: the AI Gateway proxy swallows the elicitation
  error before it reaches the client. This is why the vault exposes the
  out-of-band browser UI (`tokens.internal.willpxxr.com`, WEP-0006
  decision 4) instead of prompting in-session.

So in v1.1.0 there is no way for Envoy to attach *any* upstream credential
at the MCP backend hop, let alone a per-caller one. The only per-caller-
capable injection point is a proxy in the data path.

## Decision

- **MCP backends that need upstream credentials ride the vault's proxy
  listener.** One generic listener (`PROXY_PORT`, 8081), path-dispatched by
  the first path segment; the MCPRoute backendRef (`linear`, path
  `/linear`) selects the provider. The Backend name is the tool prefix
  (`linear__*`) and deliberately matches the path segment (the provider
  key). No per-provider ports: providers are enumerated by
  `PROVIDER_<NAME>_UPSTREAM_URL` env, and adding one is env config plus a
  backendRef -- no new ports or Services.
- **The vault remains the credential lifecycle owner**: refresh ahead of
  expiry + on-401 retry, envelope-encrypted storage in Supabase, connect
  flow via the out-of-band UI.
- **Multi-user is deferred, not designed away**: the credentials table
  already keys on `(provider, principal)`. Activating it means forwarding
  the caller's identity to the vault on the linear backendRef
  (`claimToHeaders`/`forwardHeaders` -- v1.0 feature) and resolving
  per-principal in the proxy. No schema or route-structure change needed.
- **Revisit upstream**: when `MCPBackendSecurityPolicy` gains
  `credentialOverride` (parity with PR #2253) or the roadmap's `MCPBackend`
  CRD lands, the migration is mechanical: point the backendRef back at
  `mcp.linear.app` direct (plus `BackendTLSPolicy`), re-add the extAuth
  check against the vault's `/authz`, and resolve
  `credentialOverride.fromDynamicMetadata` (namespace
  `envoy.filters.http.ext_authz`) per caller -- the vault keeps lifecycle +
  UI and shrinks back to control plane. Track the `MCPBackend` roadmap item
  (v1.0 release notes) and #2216/#2253.

## Consequences

- `+` Works today, on released software, with no plaintext secrets outside
  the vault's envelope-encrypted database.
- `+` Per-caller injection (multi-user) is a small increment on the same
  path, not a redesign.
- `-` One extra in-cluster hop for vault-backed MCP calls (availability +
  latency). Per-backend opt-in bounds the blast radius: any backend can go
  static-key direct by editing one ref (WEP-0006 rollback note).
- `-` The vault is on the critical path for linear tool calls; a vault
  outage degrades Linear (other backends unaffected).
- `-` Tool names carry no provider-credential distinction beyond the
  prefix; per-principal rows are invisible to clients (intended).

## References

- envoyproxy/ai-gateway PR #2253 (credentialOverride, LLM routes only),
  issue #2216
- v1.0 release notes ("What's Next": dedicated `MCPBackend` CRD, deeper MCP
  authorization)
- WEP-0006 (the vault RFC; decision 1 amendment mirrors this ADR in brief)
- WEP-0002 (same defer-per-caller pattern for kagent-tools' k8s identity)
