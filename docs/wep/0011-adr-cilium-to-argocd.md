# WEP-0011: Cilium under ArgoCD (moved out of the talos module)

**Status**: Accepted
**Date**: 2026-09-04
**Type**: ADR

## Context

Cilium was installed and managed by the `hcloud-talos` module
(`deploy_cilium` → `data.helm_template` render → ~30 `kubectl_manifest`
resources): config lived in `terraform/files/cilium-values.yaml`, changes
required a TF apply, drift was invisible (render-then-apply, no reconciliation
loop), and the CNI was the one core component outside GitOps. The 2026-09-04
incident made GitOps ownership of the CNI config the obvious want — config
drift was central to the outage's blast radius.

## Decision

- **`apps/cilium/`** (`app.yaml` + `values.yaml`): helm chart `cilium` 1.16.2
  from `https://helm.cilium.io`, releaseName `cilium`. The ApplicationSet's
  global `ServerSideApply=true` adopts the previously-unowned objects.
- **Zero-churn migration**: `values.yaml` pins the exact running images
  (tag@digest via `image.override`) and matches the live `cilium-config`
  (verified by rendering the chart and diffing the ConfigMap: three
  empty-string cosmetic deltas, and one real mismatch — `bpf-lb-acceleration`
  live=`disabled` vs the module's current-code intent `best-effort`; migrated
  as `disabled` to match live, with the flip deferred to its own commit).
- **Module side**: `deploy_cilium = false`. The `removed` block **cannot** be
  used for module-internal resources — Terraform rejects it while the
  resource block still exists in the module source, even with the for_each
  gate closed. The instances were therefore removed from state via
  `terraform state pull` → filter (also scrubbing dangling `dependencies`
  references) → `terraform state push -ignore-remote-version` (serial
  bumped). No destroy: the live objects were never touched by TF.
- `terraform/files/cilium-values.yaml` deleted; its content moved (with the
  fixes below) to `apps/cilium/values.yaml`.

## Consequences

- Cilium config changes are git commits → ArgoCD syncs; drift is detected.
- **Do not re-enable `deploy_cilium`** — it would re-render the manifests and
  two-manage the CNI.
- Follow-up (separate commit): consider
  `loadBalancer.acceleration: best-effort` (the module's intent for the
  tailscale LB path) as a reviewed change of its own.
- Chart version bumps happen in `apps/cilium/app.yaml` (WEP-0009 Phase B's
  Cilium step lives there), with the digest pins in `values.yaml` updated in
  the same commit.
- The same handoff pattern (state pull/filter/push, not `removed` blocks)
  applies to any other module-internal resource that moves to GitOps.
