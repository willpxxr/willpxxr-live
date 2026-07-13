---
name: new-gitops-app
description: Scaffold a new component under gitops/clusters/de/hetzner/cluster/apps/, following this repo's established conventions (network policy posture, secrets pattern, Flux registration), instead of re-deriving the file layout from scratch or copying an existing app ad hoc.
---

# New GitOps App

Read `CLAUDE.md`'s "GitOps app conventions" section first — this skill is the
executable version of that section. If the two ever disagree, `CLAUDE.md` is wrong
and should be fixed as part of this change (see its "Keeping this file current"
section).

## 1. Establish the shape before writing files

Ask (or infer from the task) before scaffolding:

- **App name** and **target namespace** (usually the same).
- **Install method**: this repo's `ResourceSetInputProvider` pattern (default —
  use unless there's a specific reason not to) vs. a plain `HelmRelease` (only
  when a pinned chart version or install-time flags matter, as with
  `envoy-gateway`/`envoy-ai-gateway`) vs. plain manifests (no Helm chart at all,
  e.g. `apps/gateway/`).
- **External dependencies**: does it need egress to a specific third-party host
  (needs its own `allow-<name>-egress` network policy rule), the API server, DNS,
  or another namespace's pods (needs an ingress/egress rule naming that namespace)?
- **Secrets**: does it need one from 1Password? Is the secret's value something a
  human must paste in, or can a Terraform provider resource produce it (prefer the
  latter — see `openrouter.tf`/`tailscale.tf`/`betterstack.tf` for the pattern of a
  provider resource + `onepassword_item` writing into the `kubernetes` vault)?

## 2. Files to create

```
apps/<name>/
├── namespace.yaml
├── network-policy.yaml       # see the CiliumNetworkPolicy conventions in CLAUDE.md
├── kustomization.yaml        # lists the above + configMapGenerator if using values.yaml
├── config.yaml                # ResourceSetInputProvider, if using the chart pattern
├── values.yaml                 # Helm values, if using the chart pattern
└── externalsecret.yaml        # if it needs a secret from 1Password
```

`config.yaml` template (chart pattern):

```yaml
---
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSetInputProvider
metadata:
  name: <name>
  namespace: flux-system
  labels:
    fluxcd.controlplane.io/resourceset: charts
spec:
  type: Static
  defaultValues:
    name: "<name>"
    namespace: "<namespace>"
    repoURL: "<helm repo url>"
    chart: "<chart name>"
    valuesConfigMap: "<name>-values"
```

`kustomization.yaml` template (chart pattern):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - network-policy.yaml
  - config.yaml
configMapGenerator:
  - name: <name>-values
    namespace: flux-system
    files:
      - values.yaml
generatorOptions:
  disableNameSuffixHash: true
```

Then add `flux-system/kustomization-<name>.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: <name>
  namespace: flux-system
spec:
  interval: 10m0s
  path: "./gitops/clusters/de/hetzner/cluster/apps/<name>"
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true
  # Only if there's a real ordering dependency (e.g. ExternalSecret needs the store):
  # dependsOn:
  #   - name: external-secrets-secretstore
  # Only if there's a HelmRelease to health-check:
  # healthChecks:
  #   - apiVersion: helm.toolkit.fluxcd.io/v2
  #     kind: HelmRelease
  #     name: <name>
  #     namespace: flux-system
```

And register it in `flux-system/kustomization.yaml`'s `resources` list.

## 3. Before considering it done

Run the `verify-infra-change` skill against everything you just wrote.

## 4. Learning loop

If this app needed a file or pattern this skill doesn't mention (a new kind of
network policy shape, a new secret-provisioning pattern, a reason to deviate from
the chart pattern), add it here and to `CLAUDE.md` — don't let it become a
one-off that the next scaffold has to rediscover from `git log`.
