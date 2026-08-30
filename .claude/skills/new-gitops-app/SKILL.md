# Skill: new-gitops-app

Read `AGENTS.md`'s "GitOps app conventions" section first — this skill is the
executable version of that section. If the two ever disagree, `AGENTS.md` is wrong
and should be fixed as part of this change (see its "Keeping this file current"
section).

## 1. Establish the shape before writing files

Ask (or infer from the task) before scaffolding:

- **App name** and **target namespace** (usually the same; omit the namespace in
  app.yaml only for cluster-scoped apps).
- **Source kinds** (any combination, see WEP-0001): `helm:` entries
  (`repoURL`/`chart`/`version`/`releaseName` + per-entry `values:` file),
  `kustomize:` entries (`repoURL`/`path`/`revision`), and/or `manifests:`
  (path globs of the dir's own plain manifests — nothing is implicit).
- **External dependencies**: third-party SaaS egress (world:443 rule +
  description), API-server access (every watching controller!), other
  namespaces, and — for any UI/exposure app — an egress rule in
  `apps/envoy-gateway/network-policy.yaml`'s `allow-backend-egress`.
- **Secrets**: `ExternalSecret` + `refreshInterval: 6h` (admission-enforced);
  Terraform-generated items preferred when a provider exists (see AGENTS.md).

## 2. Files to create

```
apps/<name>/
├── app.yaml                 # the app definition (rendered by the ApplicationSet)
├── namespace.yaml           # unless the namespace is bootstrap-owned (external-secrets/tailscale/argocd)
├── network-policy.yaml      # default-deny posture — always
├── values.yaml              # helm apps: consumed via valueFiles, never synced as a manifest
├── externalsecret.yaml      # if it needs a secret from 1Password
└── <other manifests>        # each listed in app.yaml's `manifests:`
```

`app.yaml` template (helm + manifests, the common shape):

```yaml
name: <name>
namespace: <namespace>
helm:
  - repoURL: https://charts.example.com   # OCI: full artifact path (oci://registry/path/chart)
    chart: <chart-name>                   # basename; for OCI see AGENTS.md
    version: <pinned version>             # REQUIRED for helm sources (empty/omitted fails spec validation)
    releaseName: <release-name>           # keep stable — it's the helm release identity
    values: values.yaml
manifests:               # path globs relative to the app dir, synced as plain manifests
  - namespace.yaml
  - network-policy.yaml
```

There is no registration step — `argocd/apps-applicationset.yaml` renders the
Application automatically from the app.yaml; adding the directory IS the
deployment (next push to main syncs it, selfHeal + prune enabled).

## 3. Before considering it done

Run the `verify-infra-change` skill against everything you just wrote.

## 4. Learning loop

If this app needed a file or pattern this skill doesn't mention (a new kind of
network policy shape, a new secret-provisioning pattern, a reason to deviate
from the helm/manifest pattern), add it here and to `AGENTS.md` — don't let it
become a one-off that the next scaffold has to rediscover from `git log`.
