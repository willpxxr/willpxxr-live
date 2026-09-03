# RFC-0009: Talos/Kubernetes upgrade strategy

**Date:** 2026-09-03 · **Status:** Accepted (phased rollout — tracked in
[INF-13](https://linear.app/willpxxr/issue/INF-13); INF-13's "WEP-0008"
reference predates ADR-0008 taking that number)

## Context

Cluster: single CX23 control plane + 2 CX23 workers, Talos v1.12.2 /
Kubernetes 1.35.0. Upgrades to date have never been exercised; the 2026-09-03
reboot-loop incident (ADR-0007) showed that machine-config/extension contracts
silently break across version jumps, and that the provision path (Packer →
boot → *verify RUNNING*) is the only thing that catches them.

Constraints discovered along the way:

- The `hcloud-talos` module seeds machine config at provision only;
  `user_data` is `lifecycle.ignore_changes` — TF version bumps never reach
  live nodes (verify-infra-change §1).
- The tailscale system extension requires an `ExtensionServiceConfig`
  (ADR-0007); the schematic is content-addressed — Image Factory re-POSTing
  `packer/talos/schematic.yaml` deterministically returns schematic ID
  `7d4c31cbd96db9f90c874990697c523482b2bae27fb4631d5583dcd9c281b1ff`, which is
  therefore the stable installer-image reference for in-place upgrades:
  `factory.talos.dev/installer/7d4c31cb…:v<version>`.
- Extension *versions* are resolved by the factory per Talos version — the
  config contract must be re-verified after every Talos bump (ADR-0007).
- WEP-0005 pod-certificate alpha gates live in machine config on the live CP;
  a k8s bump that renames/GAs those gates changes machine config → lands via
  one-time `talosctl apply-config`, never via TF.
- Cilium 1.16.2 predates k8s 1.36 support — the Cilium upgrade is a
  prerequisite of the k8s phase, not something bundled into it.

## Decision

Two separate operations, smallest blast radius each:

### Phase 0 — prep (declarative)

1. Bump `packer/talos/talos.pkr.hcl` default → v1.13.9 (this commit). The
   talos-image workflow builds the snapshot automatically (paths-filtered
   push trigger).
2. After the snapshot exists: bump `hetzner.tf` `talos_version` → v1.13.9
   (future provisions only; `kubernetes_version` stays 1.35.0 until Phase B).
3. Pre-flight: `talosctl etcd snapshot` (off-node) + `hcloud server
   create-image` per node (full-disk rollback), etcd health, client ≥ target.

### Phase A — Talos-only bump (rehearsal)

1. **Throwaway validation**: provision a temporary worker from the new
   snapshot (TF `worker_nodes` id 3 — the module pulls the newest `os=talos`
   snapshot and our `talos_worker_extra_config_patches` ships the tailscale
   config at provision). Assert: machine `running`, `ext-tailscale` joined,
   node Ready, Cilium healthy, WEP-0005 gates present, 30 min clean.
2. **Control plane, in place**: `talosctl -n 10.0.1.101 upgrade --image
   factory.talos.dev/installer/7d4c31cb…:v1.13.9` → verify etcd member +
   machine `running`. ~2–3 min API blip; `talosctl rollback` is the escape.
3. **Workers, blue/green**: validated throwaway stays → drain + TF-destroy
   worker-1 → CCM cleans the node object → repeat for worker-2. PVs reattach
   via CSI on reschedule.

### Phase B — Kubernetes bump (separate change)

1. Cilium upgrade first (1.16.2 → ≥1.18, own change, matrix-checked).
2. Verify WEP-0005 gate names against 1.36 (GA'd gates may be removed from
   the flag — kube-apiserver refuses to start on unknown gates); push corrected
   args to the live CP via `talosctl apply-config` runbook step if changed.
3. Bump `hetzner.tf` `kubernetes_version` (future provisions) + run
   `talosctl upgrade-k8s --to 1.36.x`.

### Phase C — verify

`talosctl health`; substrate/gates; tailscale ingress path end-to-end; ArgoCD
synced; restart counters flat; snapshot becomes canonical for future nodes.

## Consequences

- Rollback paths: `talosctl rollback` (CP, in-place), hcloud snapshot restore
  (last resort = DR drill, which INF-13 requires anyway).
- `registry.k8s.io` 403s from Hetzner ranges are a known flake
  (hcloud-talos#46) — retry `upgrade-k8s` before diagnosing.
- The hetzner.tf `talos_version` bump deliberately LAGS the packer build:
  its image data source selects the newest `os=talos` snapshot, so pushing
  the version bump before the build exists would fail the TFC apply.
