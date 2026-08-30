# RFC 0001: Replace Flux (flux-operator) with ArgoCD ApplicationSets

## Status

Proposed (2026-08-30)

## Context

The `de/hetzner` cluster is GitOps-managed by Flux, installed and self-managed
via the flux-operator's `FluxInstance` (`flux-system/flux-instance.yaml`). The
configuration layers are:

1. **flux-operator** — installs/upgrades the Flux controllers themselves, and
   hosts the UI (`apps/flux-operator-route/`).
2. **`ResourceSet` + `ResourceSetInputProvider`** (`flux-system/charts.yaml` +
   per-app `config.yaml`) — a homegrown "abstract YAML" layer: each chart app
   declares `name`/`namespace`/`repoURL`/`chart`/`valuesConfigMap`, and the
   ResourceSet templates out a `HelmRepository` + `HelmRelease`.
3. **Plain `HelmRelease`s** — for charts needing version pins, OCI repos,
   multiple releases per dir, or install flags (`envoy-gateway`,
   `envoy-ai-gateway` (+ its CRDs release), `kagent-tools`).
4. **23 Flux `Kustomization` CRs** (`flux-system/kustomization-*.yaml`) — one
   per app dir, providing ordering (`dependsOn`), `wait`, health checks, and
   prune. Plus the root `kustomization.yaml` registration list.

This is two template systems (ResourceSet templating + one Kustomization CR per
app) to get what ArgoCD provides natively: app rendering from declarative app
metadata, built-in health assessment, sync waves for ordering, and a UI.
Migrating also drops the flux-operator entirely (one less controller stack) and
replaces the ResourceSet machinery with a single declarative generator.

**Scale note**: this is an RFC rather than an ADR — it changes the repo-wide
GitOps delivery mechanism and requires a staged migration on a live cluster,
not a single recorded decision.

## Current app inventory

| App dir | Type | Chart / source | Version | Live Helm release | Wave |
| --- | --- | --- | --- | --- | --- |
| beyla | helm | grafana / beyla | latest | beyla-beyla | 4 |
| cert-manager | helm | charts.jetstack.io / cert-manager | latest | cert-manager-cert-manager | 0 |
| external-secrets | helm | charts.external-secrets.io / external-secrets | latest | external-secrets-external-secrets | 0 |
| otel-collector-agent | helm | open-telemetry / opentelemetry-collector | latest | otel-collector-otel-collector-agent | 3 |
| otel-collector-gateway | helm | open-telemetry / opentelemetry-collector | latest | otel-collector-otel-collector-gateway | 3 |
| tailscale-operator | helm | pkgs.tailscale.com / tailscale-operator | latest | tailscale-tailscale-operator | 0 |
| envoy-gateway | helm | oci://docker.io/envoyproxy / gateway-helm | 1.8.2 | envoy-gateway-system-envoy-gateway | 0 |
| envoy-ai-gateway | helm x2 | oci://docker.io/envoyproxy / ai-gateway-helm + ai-gateway-crds-helm | v1.0.0 | ...-ai-gateway + ...-ai-gateway-crds | 1 (crds: 0) |
| kagent-tools | helm | oci://ghcr.io/kagent-dev/tools/helm / kagent-tools | 0.2.1 | kagent-tools (explicit) | 2 |
| ai-gateway-llm | manifest | — | — | — | 3 |
| ai-gateway-mcp | manifest | — | — | — | 3 |
| envoy-gateway-config | manifest | — | — | — | 1 |
| gateway | manifest | — | — | — | 2 |
| cel-admission-policies | manifest | — | — | — | 0 |
| cel-admission-policies-config | manifest | — | — | — | 1 |
| external-secrets-secretstore | manifest | — | — | — | 1 |
| kube-system | manifest | — | — | — | 2 |
| tailscale-operator-secret | manifest | — | — | — | 2 |
| policy (cluster/policy/) | manifest | — | — | — | 0 |
| flux-operator-route | manifest | — | — | — | **deleted** (Flux UI goes away) |

Waves replicate the current `dependsOn` graph exactly (external-secrets →
secretstore → consumers; envoy-gateway → config → gateway → ai-gateway-*;
otel-collector → agent/gateway → beyla; cert-manager → gateway).

## Decision

**ArgoCD, self-managed via app-of-apps, with one ApplicationSet rendering all
apps from per-app `app.yaml` files.** Scope: `de/hetzner` only; the legacy
`uk/prod` cluster's Flux stays as-is.

### Target architecture

```
gitops/clusters/de/hetzner/cluster/
├── argocd/
│   ├── root-app.yaml            # app-of-apps: Application -> ./argocd (self-managed)
│   └── apps-applicationset.yaml # the single generator (below)
└── apps/<name>/
    ├── app.yaml                 # NEW: declarative app metadata (the "abstract yaml")
    ├── values.yaml              # unchanged (helm apps; inline HelmRelease values move here)
    ├── namespace.yaml           # unchanged
    └── network-policy.yaml      # unchanged
```

Bootstrap is one-time and manual (documented as a `scripts/` helper):

1. `helm install argocd argo/argo-cd -n argocd` (Tailscale-only UI; route added
   for parity with the removed Flux UI).
2. `kubectl apply -f argocd/root-app.yaml` — from then on ArgoCD syncs the
   ApplicationSet and every app from git, self-managed.

### The `app.yaml` abstraction

Each app declares its shape; one ApplicationSet (git files generator over
`apps/*/app.yaml` and `policy/app.yaml`) renders an Application per file:

```yaml
# apps/cert-manager/app.yaml
name: cert-manager
namespace: cert-manager
wave: 0
helm:                                    # omit for manifest-only apps
  - repoURL: https://charts.jetstack.io  # or oci://docker.io/envoyproxy
    chart: cert-manager
    version: ""                          # "" = track latest (RSIP parity); set to pin
    releaseName: cert-manager-cert-manager  # must match live release names (adoption)
```

The ApplicationSet template (goTemplate) renders a **multi-source
Application** per entry:

- one **helm source per `helm` entry** (`valueFiles: [values.yaml]`,
  `CreateNamespace=true`) — naturally handles envoy-ai-gateway's two releases
  (main chart + CRDs chart) from one dir;
- one **directory source** for the dir's plain manifests (namespace.yaml,
  network-policy.yaml, ...) with `exclude: app.yaml` — replicating how Flux's
  kustomize-controller applied everything in the dir alongside the chart;
- `syncPolicy.automated` + `selfHeal` + `prune`;
- `argocd.argoproj.io/sync-wave: <wave>` annotation from `wave`;
- destination namespace from `namespace`.

Manifest-only apps render the directory source alone. Waves replace
`dependsOn`; ArgoCD's built-in health assessment replaces `wait` +
`healthChecks`. Adding an app = one new directory with an `app.yaml` — same
workflow as today's `config.yaml`.

### In-place adoption (no rebuild)

- Applications reuse the **exact live Helm release names** (flux
  helm-controller's `<targetNamespace>-<name>` convention — see inventory).
  ArgoCD takes over the existing Helm releases in place; no uninstall/reinstall,
  no workload restart.
- Manifest resources are applied by ArgoCD over objects Flux created; expected
  churn is limited to manager/ownership annotation diffs.
- Flux stays installed until every ArgoCD app reports Healthy; removal is the
  **last** phase (rollback before that = delete ArgoCD Applications and Flux
  reasserts its desired state).

## Migration plan

1. **Scaffold** (docs-only risk): write `argocd/` (root-app + ApplicationSet),
   convert every HelmRelease's inline values into per-app `values.yaml`, add
   every `app.yaml`. Verify with the verify-infra-change skill plus
   `argocd admin app diff`-style dry renders where feasible.
2. **Install ArgoCD** (manual, one-time): helm install + apply root-app with
   the ApplicationSet in **manual sync** mode. Review rendered Applications
   and their diffs against live state in the UI/CLI before syncing anything.
3. **Adopt, wave by wave**: enable automated sync starting at wave 0
   (policy, external-secrets, cert-manager, envoy-gateway,
   tailscale-operator...), confirm each wave Healthy with no unexpected
   diffs/drift before the next. Helm releases must be verified as *adopted*
   (no second release revision created) at this point.
4. **Remove Flux**: delete the `FluxInstance` and all Flux CRs
   (Kustomizations, HelmReleases, HelmRepositories, ResourceSet machinery),
   then the flux CRDs, then the `flux-system` namespace and its
   network-policy; delete `apps/flux-operator-route/`.
5. **Cleanup**: update `CLAUDE.md` (GitOps conventions section),
   `.claude/skills/` (`verify-infra-change`, `new-gitops-app` are Flux-shaped),
   add the ArgoCD UI ingress/Auth0 app, update `kagent-tools` values comment
   ("runs Flux not Argo").

## Risks / mitigations

- **CRD upgrades**: ArgoCD applies a chart's `crds/` directory on install but
  does not upgrade it on subsequent syncs. Affected: cert-manager, Envoy
  Gateway/AI Gateway. Mitigation: EG/AI-Gateway CRDs ship via the AI Gateway
  CRDs chart and EG values; treat CRD bumps as an explicit manual
  `kubectl apply -f` step on chart upgrades, noted in the app dirs.
- **Helm release name mismatch** would make ArgoCD *install a second release*
  instead of adopting — the inventory table exists precisely so `releaseName`
  matches the live flux-generated names.
- **Flux/ArgoCD overlap window**: both reconciling the same objects. Keep the
  window short and one-directional (ArgoCD takes over wave by wave; Flux is
  only *removed*, never partially edited, during the window).
- **Deleting HelmRelease CRs uninstalls releases** (helm-controller GC).
  Order in phase 4 matters: `FluxInstance` delete first (takes the controllers
  down), then CRs/CRDs — never the reverse.
- **Unpinned charts drift**: RSIP apps track chart-latest today; empty
  `version` preserves that behavior (accepted as-is; pinning is an
  independent future decision).

## Rollback

Before phase 4: delete the ArgoCD Applications (or suspend the root app);
Flux is still running and reconciles everything back. After phase 4: re-apply
the FluxInstance (it self-installs Flux again from git) — same repo path still
contains the manifests, so rollback is re-bootstrap, not rebuild.

## Alternatives considered

- **Stay on Flux** and just upgrade the ResourceSet pattern — rejected: the
  operator/ResourceSet layer is still a homegrown template stack, and the
  decision was made to standardize on ArgoCD's app model and UI.
- **Plain app-of-apps** (hand-written `Application` per app, no generator) —
  rejected: loses the abstract-yaml layer that motivates the change; ~20
  verbose Application manifests instead of ~20 small `app.yaml` files.
- **Kustomize `helmCharts:` in every app dir** (single directory-source
  generator) — rejected: template-render only, no Helm release/rollback
  semantics, complicates in-place adoption.

## Open questions

- Keep the flux-default Helm release names long-term (ugly but already live)
  or schedule a rename cycle post-migration? Default: keep.
- ArgoCD UI exposure: Tailscale + Auth0 SecurityPolicy, mirroring the old Flux
  UI route. Default: yes, in phase 5.
