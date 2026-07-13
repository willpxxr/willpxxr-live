---
name: verify-infra-change
description: Validate a pending change to this repo (Terraform + FluxCD/Kubernetes manifests) locally before pushing to main, so mistakes surface here instead of a live Terraform apply or a stuck Flux reconciliation (this repo pushes straight to main -- no PR/plan-only gate in between).
---

# Verify Infra Change

This repo pushes straight to `main` (single-developer homelab, no PR step) and has
no CI that renders/dry-runs the actual config first — Terraform Cloud applies on
every push to `main`, and nothing validates `gitops/` manifests at all until Flux
tries to apply them live. Run this yourself before pushing.

## 1. Terraform

For every changed/added `.tf` file:

```
terraform fmt -check -diff <files...>
```

If new provider blocks or resources were added, also sanity-check
`terraform validate` if a local init is feasible — but don't run
`terraform apply`/`plan` locally against the real workspace; that's Terraform
Cloud's job once pushed.

## 2. Kubernetes manifests (`gitops/`)

Use the live cluster's context (`kubectl config get-contexts`) for a real
server-side schema check against the actual installed CRDs — this catches typos in
CRD fields (e.g. `EnvoyProxy`, `CiliumNetworkPolicy`, `ExternalSecret`,
`ResourceSetInputProvider`, `ReferenceGrant`) that a generic YAML linter would miss:

```
kubectl apply --dry-run=client -f <file> -o yaml
```

Note: plain `kustomization.yaml` / bare Helm `values.yaml` files aren't real k8s
objects — `kubectl apply` on those will correctly error with `kind not set`; that's
expected, not a failure. Only dry-run the actual manifests (namespace,
network-policy, externalsecret, config/ResourceSetInputProvider, referencegrant,
etc.).

If `pyyaml`/`yq` aren't installed, don't bother installing them just for a syntax
check — `kubectl --dry-run=client` already both parses the YAML and validates the
schema in one step, which is strictly more useful.

## 3. Helm-values-backed apps

For any app using this repo's `ResourceSetInputProvider` pattern (a `config.yaml` +
`values.yaml` pair, see `CLAUDE.md`), render the actual chart to confirm the
`values.yaml` produces the intended config — the chart's own values-merge
semantics (deep-merge maps, but a list at the same path fully replaces, not
appends) are easy to get subtly wrong:

```
helm repo add <repo-name> <repoURL from config.yaml>   # if not already added
helm repo update <repo-name>
helm template <release-name> <repo-name>/<chart> \
  -f apps/<app>/values.yaml --namespace <namespace>
```

Read the rendered output, don't just check the exit code — confirm:

- the pipelines you touched reference the exporters/receivers/processors you
  intended (a values-merge mistake often produces a *valid* but *wrong* pipeline,
  which `helm template` alone won't flag as an error)
- any preset you enabled actually added what its comment in the chart's default
  `values.yaml` says it adds (`helm show values <repo>/<chart>` to check)
- required values the chart added in a breaking release are actually set — e.g.
  `open-telemetry/opentelemetry-collector` started hard-failing on unset
  `image.repository` in a recent version; a chart bump can introduce a new one of
  these at any time, so re-check `helm template`'s error output rather than
  assuming last time's values.yaml still satisfies the chart

## 4. Learning loop

If this pass catches something not covered above (a new CRD's quirk, a chart's
breaking-change gotcha, a merge-semantics surprise), add it to this file before
moving on — the next run should not have to rediscover it.
