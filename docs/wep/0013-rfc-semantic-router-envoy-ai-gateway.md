# WEP-0013: Semantic auto-routing on the AI gateway (vLLM Semantic Router)

**Status**: draft — accepted direction: plug into the existing Envoy AI
Gateway (no agentgateway adoption)
**Type**: RFC

## Problem

The LLM proxy routes every prompt to whatever model the client picked
(`syn:*`/`hf:*`). Work is heterogeneous — routine chat doesn't need the
frontier model — but nothing selects per request, and asking users to pick
well is exactly the failure mode agentgateway's cost blogs document (~40%
spend reduction from prompt-classified routing).

## Direction (per decision)

Keep **Envoy AI Gateway** as the gateway. Add the **vLLM Semantic Router
(vSR)** — a prompt-classification service, not a proxy — and attach it to the
existing Gateway via Envoy Gateway's `EnvoyExtensionPolicy` (live CRD
verified: v1alpha1 serves `extProc`).

- vSR classifies the prompt (category + optional PII detection) and rewrites
  the request's `model` field to the category's model.
- The AI extproc/gateway then routes/meters as it does today (single
  `syn|hf:` route; the upstream sees the rewritten model).

## Design

1. **`apps/semantic-router/`**: namespace `vllm-semantic-router-system`,
   default-deny network policy (+ world:443 egress for the HF classifier
   model download, kube-dns), and the vSR helm chart **vendored** at
   `chart/` (upstream publishes no OCI chart — verified 403) consumed via a
   kustomize `helmCharts:` entry with `values.yaml`'s `configOverride`:
   category→model mapping. Initial mapping (adjustable in git):
   - general / default → `syn:small`
   - coding, math, reasoning → `syn:large`
2. **`apps/ai-gateway-llm/`**: an `EnvoyExtensionPolicy` targeting the
   Gateway: extProc → `semantic-router` Service (gRPC), processing the
   request body.
3. **Ordering** (to verify at build): whether the extension extproc runs
   before or after the AI extproc. Either works (the upstream still receives
   the rewritten model); "before" is preferred so routing/metrics record the
   classified model. If ordering can't be controlled, document which side of
   the accounting the model name lands on.
4. **NP wiring**: envoy data plane → vSR gRPC; vSR → HF (443) + kube-dns;
   nothing else.

## Alternatives considered

- **agentgateway + its vSR integration**: the upstream-documented path
  (agentgateway calls vSR as ExtProc natively), but it means adopting a new
  gateway stack beside/replacing Envoy AI Gateway — rejected for now.
- **vSR's bundled Envoy Gateway in front**: a second EG control plane +
  data plane for a transform the policy CRD can attach to the existing
  gateway.
- **EnvoyPatchPolicy injection**: brittle xDS patching.

## Consequences

- One more small service (~1 vCPU/1–2 GB, classifier models pulled from HF
  at startup — pin the model revisions).
- Model accounting: whichever component sits first sees the original model;
  note it in the runbook once ordering is verified.
- False classifications only shift cost/quality, never availability —
  requests always route.
- If EnvoyExtensionPolicy extproc cannot coexist with the AI extproc
  (filter-chain conflict), fall back to the vSR-bundled-Envoy path (2) and
  record why.

## Implementation record (2026-09-04/05) — ext-proc invocation BLOCKED, evidence trail

Deployed: vendored vSR chart v0.3.0 (lean: keyword signals, hf: modelCards —
the `syn:*` aliases are dead upstream), `EnvoyExtensionPolicy` retargeted at
the generated LLM HTTPRoutes (`ai-gateway-llm`,
`ai-gateway-llm-synthetic-anthropic`; Gateway-scoped attachment skips
AI-controller routes), `ReferenceGrant` for the cross-namespace ext-proc
backendRef, NP wiring. vSR: 1/1 Running at 512Mi, no model downloads
(lean mode).

BLOCKER: the extproc filter never invokes (cluster `upstream_rq_total: 0`
on both envoy replicas) while the AI gateway's own extproc serves all
traffic. Verified working: policy Accepted (grant), HCM-level filter enabled
with the correct cluster + `request_body_mode: BUFFERED`, per-route configs
present on ALL LLM route entries with exact filter-name match.

Root-cause lead: EG renders the per-route config for the extension filter as
`{"@type": "envoy.config.route.v3.FilterConfig", "config": {}}` — an EMPTY
generic FilterConfig rather than a real `ExtProcPerRoute`. Envoy gets an
empty per-route override and never dials the processor. Suspected EG
limitation/bug in extension-policy attachment on AI-gateway co-generated
routes.

Debug scars (for the next attempt):
- The chart's values.yaml is a duplicate-key minefield (3× `image:` blocks —
  the later `pullPolicy: Never` wins; an uncommented hostPath `extraVolumes`
  violating PodSecurity baseline; a default `providers.models` that fails
  cross-validation against routing.modelCards; `global.router.model_selection`
  ML paths that trigger the mmbert download; and `mmbert_model_path` is a
  GO-LEVEL default (`canonical_defaults.go`) that YAML nulls cannot remove —
  override with an explicit empty string).
- vSR's CR reconciler watches namespace `default` by default (the
  IntelligentPool/IntelligentRoute CRs for the CR-driven refactor need the
  namespace configured or CRs placed there).
- ArgoCD's diff normalizer rejects plain `[]` in jqPathExpressions (use the
  null-safe `[]?.`) — a bad expression breaks comparison for ALL apps.
- This ArgoCD version does not support chart-in-git helm sources (`chart:`
  field → repo-index 404); git-hosted charts go via `path` (appset change).

Next options: (a) EG upgrade / upstream issue with the empty-FilterConfig
evidence; (b) the Lua-after-AI-extproc path (the AI gateway's v0.6+ slot)
calling vSR's classify API to rewrite the model; (c) the CR-driven refactor
(IntelligentPool/IntelligentRoute) once invocation works. The chain is
fail-open: requests always work, just without classification.
