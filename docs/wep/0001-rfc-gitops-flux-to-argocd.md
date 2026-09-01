# WEP-0001 (RFC): Replace Flux (flux-operator) with ArgoCD ApplicationSets

## Status

Accepted, implemented (2026-08-30) — all five phases shipped the same day;
the ignoreDifferences + ESO hardening that fell out of phase 3 landed in
follow-up commits the same day.

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
metadata, built-in health assessment, and a UI. Migrating also drops the
flux-operator entirely (one less controller stack) and replaces the ResourceSet
machinery with a single declarative generator.

**Type**: RFC (expanded WEP) -- it changes the repo-wide GitOps delivery
mechanism and requires a staged migration on a live cluster, not a single
recorded decision; single-decision changes use the ADR subtype instead
(see `docs/wep/README.md`).

## Current app inventory

| App dir | Type | Chart / source | Version | Live Helm release |
| --- | --- | --- | --- | --- |
| beyla | helm | grafana / beyla | latest | beyla-beyla |
| cert-manager | helm | charts.jetstack.io / cert-manager | latest | cert-manager-cert-manager |
| external-secrets | helm | charts.external-secrets.io / external-secrets | latest | external-secrets-external-secrets |
| otel-collector-agent | helm | open-telemetry / opentelemetry-collector | latest | otel-collector-otel-collector-agent |
| otel-collector-gateway | helm | open-telemetry / opentelemetry-collector | latest | otel-collector-otel-collector-gateway |
| tailscale-operator | helm | pkgs.tailscale.com / tailscale-operator | latest | tailscale-tailscale-operator |
| envoy-gateway | helm | oci://docker.io/envoyproxy / gateway-helm | 1.8.2 | envoy-gateway-system-envoy-gateway |
| envoy-ai-gateway | helm x2 | oci://docker.io/envoyproxy / ai-gateway-helm + ai-gateway-crds-helm | v1.0.0 | ...-ai-gateway + ...-ai-gateway-crds |
| kagent-tools | helm | oci://ghcr.io/kagent-dev/tools/helm / kagent-tools | 0.2.1 | kagent-tools (explicit) |
| ai-gateway-llm | manifest | — | — | — |
| ai-gateway-mcp | manifest | — | — | — |
| envoy-gateway-config | manifest | — | — | — |
| gateway | manifest | — | — | — |
| cel-admission-policies | manifest | — | — | — |
| cel-admission-policies-config | manifest | — | — | — |
| external-secrets-secretstore | manifest | — | — | — |
| kube-system | manifest | — | — | — |
| tailscale-operator-secret | manifest | — | — | — |
| policy (cluster/policy/) | manifest | — | — | — |
| flux-operator-route | manifest | — | — | **deleted** (Flux UI goes away) |

The Live Helm release column exists because `releaseName` must match these
names exactly for ArgoCD to adopt the existing releases (see adoption).

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
    ├── app.yaml                 # every app: declarative metadata (the "abstract yaml")
    ├── values.yaml              # helm apps only; consumed by the helm source,
    │                            #   never synced as a manifest
    └── <manifests>              # only the files the app.yaml `manifests` list
                                 #   declares (today: namespace.yaml, network-policy.yaml)
```

An app declares any combination of three source kinds in `app.yaml`; they
compose freely because the rendered Application is multi-source and syncs all
declared sources as one unit:

1. **helm** (`helm:`) — one entry per Helm release (a chart app's norm). Rare
   minimal case: helm-only, no `manifests:` — the dir is just `app.yaml` +
   `values.yaml`. Rare here by convention (see below).
2. **kustomize** (`kustomize:`) — one entry per kustomize target, for
   components distributed as kustomize (a git repo + path + revision) rather
   than as a chart. None today; part of the schema so the abstraction is
   complete.
3. **jsonnet** (`jsonnet:`) — one entry rendering `.jsonnet` files from the
   app dir as a git-local source (path = the app dir). Added 2026-09-01 for
   the one thing plain manifests can't do: **ArgoCD build-env substitution**
   (`$ARGOCD_APP_*` reaches Helm/Kustomize/Jsonnet/CMPs only — a directory
   source's plain YAML gets none). The TLAs map passes values referencing
   build-env vars into the templates; first user is mcp-token-vault's
   `deployment.jsonnet`, whose pod-template annotation is the rendered
   revision so new commits roll the pod onto the freshly built `:main`
   image without manual bumps. Keep Jsonnet scoped to this: it's a
   templating escape hatch, not an invitation to rewrite apps as code.
4. **manifests** (`manifests:`) — the app dir's own plain manifests
   (`namespace.yaml`, `network-policy.yaml`, ...). Every chart app in this
   repo carries `network-policy.yaml` (the default-deny posture convention),
   so the typical helm app declares
   `manifests: [namespace.yaml, network-policy.yaml]`. A **manifest-only**
   app (no `helm:`/`kustomize:`/`jsonnet:`) is just a `manifests:` list
   (`ai-gateway-llm`, `gateway`, `policy`, ...).

Bootstrap is one-time and manual (documented as a `scripts/` helper):

1. `helm install argocd argo/argo-cd -n argocd` (Tailscale-only UI; route added
   for parity with the removed Flux UI).
2. `kubectl apply -f argocd/root-app.yaml` — from then on ArgoCD syncs the
   ApplicationSet and every app from git, self-managed.

### The `app.yaml` abstraction

Each app declares its shape; one ApplicationSet (git files generator over
`apps/*/app.yaml` and `policy/app.yaml`) renders an Application per file:

```yaml
# helm + manifests -- today's norm for chart apps (e.g. external-secrets)
name: external-secrets
namespace: external-secrets
helm:                                            # omit for manifest-only apps
  - repoURL: https://charts.external-secrets.io  # or oci://docker.io/envoyproxy
    chart: external-secrets
    version: ""          # "" = track latest (RSIP parity); set to pin
    releaseName: external-secrets-external-secrets  # must match live name (adoption)
    values: values.yaml  # consumed by the helm source; never synced as a manifest
manifests:               # path globs relative to the app dir, synced as plain manifests
  - namespace.yaml
  - network-policy.yaml
```

```yaml
# helm-only (minimal shape) -- dir contains app.yaml + values.yaml and nothing
# else; hypothetical today, since the network-policy convention applies to
# every app's namespace
name: some-chart-app
namespace: some-ns
helm:
  - repoURL: https://charts.example.com
    chart: some-chart
    version: ""
    releaseName: some-ns-some-chart
    values: values.yaml
```

```yaml
# manifest-only -- no helm key; manifests lists every file to sync
name: gateway
namespace: envoy-gateway-system
manifests:
  - gateway.yaml
  - gateway-ingress.yaml
  - hubble-ingress.yaml
  - issuer.yaml
  - certificate.yaml
```

```yaml
# all three kinds at once -- one Application, one sync unit
name: combo-app
namespace: combo
helm:
  - repoURL: https://charts.example.com
    chart: some-chart
    version: ""
    releaseName: combo-some-chart
    values: values.yaml
kustomize:
  - repoURL: https://github.com/some-org/kustomized-component
    path: deploy/overlays/production
    revision: ""         # "" = track the repo's default branch
manifests:
  - namespace.yaml
  - network-policy.yaml
```

`manifests` semantics: a list of path globs (relative to the app dir) synced
as plain manifests via one directory source whose `include` pattern is built
from the list. **Nothing is synced implicitly** — a file only lands on the
cluster if it's listed. That makes `app.yaml` the app's index and keeps
stray/scratch files from being applied by accident (something Flux's
directory-scanning behavior allowed). The tradeoff: adding a manifest file
means touching `app.yaml` in the same commit, or the file silently never
syncs — the `verify-infra-change` skill should diff app dirs against their
`manifests` lists. `app.yaml` and `values.yaml` are never synced as manifests
(they're simply not listed). `kustomize` entries take `repoURL`/`path`/
`revision` (revision "" = track the default branch); `helm` entries take an
optional per-entry `values:` filename, so multi-release dirs like
envoy-ai-gateway don't have to share one values file.

The ApplicationSet template (goTemplate) renders one **multi-source
Application** per app, combining every declared source kind. The uniform
fields live in the struct template; the variable-shaped `sources` block (and
`destination.namespace`, when the app declares one) is a `templatePatch` —
ApplicationSet's struct template only templates string fields and cannot emit
conditional or variable-length source lists:

- one **helm source per `helm` entry** (`valueFiles` from the entry's
  `values:` file, `CreateNamespace=true`) — handles envoy-ai-gateway's two
  releases (main chart + CRDs chart) from one dir, each with its own values
  file if needed;
- one **kustomize source per `kustomize` entry** (`path` + `targetRevision`);
- one **directory source** when `manifests` is non-empty: `include` built from
  the list — replicating how Flux's kustomize-controller applied the dir's
  plain manifests alongside the chart, but explicit and per-file rather than
  implicit;
- `syncPolicy.automated` + `selfHeal` + `prune` + `retry` (backoff);
- destination namespace from `namespace`.

Manifest-only apps render the directory source alone. **No cross-app ordering
is encoded** — deliberately, and this replaces the whole `dependsOn` graph:
Flux needed `dependsOn` because a kustomization that references a not-yet-
created CRD fails its apply and sits degraded; in ArgoCD the equivalent
failure is an Application whose sync fails and **retries with backoff**
(`syncPolicy.retry`) until the dependency (a CRD from another app's chart,
etc.) lands, then converges with no further intervention. ArgoCD's built-in
health assessment replaces `wait` + `healthChecks`. (Within a single
Application, ArgoCD still applies namespaces and helm `crds/` before the rest,
so intra-app ordering needs no help either.) Adding an app = one new directory
with an `app.yaml` — same workflow as today's `config.yaml`.

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
3. **Adopt**: enable automated sync on all Applications (order doesn't matter;
   apps whose CRDs aren't in place yet retry and converge). Confirm every app
   ends Healthy/Synced and that Helm releases were *adopted* (no second
   release revision created).
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
  window short and one-directional (ArgoCD takes over; Flux is only *removed*,
  never partially edited, during the window).
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
