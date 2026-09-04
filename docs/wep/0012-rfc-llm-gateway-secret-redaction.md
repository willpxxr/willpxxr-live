# WEP-0012: Secret redaction on the LLM gateway path

**Status**: draft — for discussion
**Type**: RFC

## Problem

Clients of the LLM proxy (`ai.internal.willpxxr.com` → `api.synthetic.new`)
send arbitrary prompt bodies; pasted secrets (API keys, tokens, private keys)
leave the cluster toward a third-party provider. Envoy AI Gateway has **no
usable native redaction for the wire path** (verified 2026-09-04):

- the v0.6.0 release note announces "request and response body redaction",
  but it scopes to telemetry ("before they hit logs, traces, or metrics"),
- the v1.1.0 controller's live CRDs (`AIGatewayRoute`, `AIServiceBackend`,
  `GatewayConfig`, `BackendSecurityPolicy`) expose no redaction fields,
- the telemetry path is moot here anyway (the otel stack is disabled).

## Proposal

`services/llm-redactor` — a small Go reverse proxy (stdlib + regexp only,
pattern: `mcp-token-vault`) inserted as the `Backend` target for the
synthetic backends; it forwards to `api.synthetic.new:443` with the injected
provider key untouched.

- **Requests**: buffered JSON parse, walk `messages[].content` (strings +
  content blocks), apply detectors, rewrite, forward.
- **Detectors**: `sk-…`/`sk-proj-…`, `gh[pousr]_…`, `tskey-auth-…`, `ops_…`,
  AWS `AKIA…`/`ASIA…`, Slack `xox…-`, JWTs (`eyJ…` — covers Supabase keys),
  `AIza…`, basic-auth-in-URL, PEM blocks, high-entropy-run fallback.
  Replacement: `[REDACTED:<detector>:fp<8>]` (sha256 fingerprint — log-safe
  correlation without recovery).
- **Responses**: SSE-aware — per-line redaction with a ~128-byte carry buffer
  so matches split across chunks still hit.
- **Rollout**: shadow mode first (log detector + fingerprint + location only)
  for a bake period, then `enforce: true` via a git commit. Failure mode:
  open-circuit (pass through) + loud metric.
- **Wiring**: one manifest diff in `apps/ai-gateway-llm/` (backend endpoints
  → redactor Service, `BackendTLSPolicy` retarget). All gateway auth, model
  extraction, rate limits, and the anthropic/syn route split stay untouched.

## Alternatives considered

- **Envoy AI Gateway native**: telemetry-only, no CRD surface (above).
- **Envoy `ext_proc` via `EnvoyPatchPolicy`**: full body mutation at the
  proxy, but xDS-patch brittleness re-verified on every Envoy Gateway upgrade.
- **Lua filter**: no JSON library; dead end.

## Consequences

- One more hop (in-cluster, negligible) and one more service to maintain.
- False-positive risk handled by the shadow period + fingerprint logs.
- If Envoy AI Gateway later ships wire-level redaction natively, retire the
  sidecar and revert the backend swap.
