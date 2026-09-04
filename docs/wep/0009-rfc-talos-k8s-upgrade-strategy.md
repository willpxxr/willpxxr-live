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
- WEP-0005 pod-certificate alpha gates: post-incident verification showed the
  substrate gates are **branch-only and never served live** (no runtime-config
  flag, no ClusterTrustBundle API), so a k8s bump carries no gate-removal risk
  in practice. Should machine config ever need changing for a k8s bump, the
  2026-09-04 rule applies: no `talosctl apply-config` — the change lands in
  `hetzner.tf` and the CP is drained, tainted, and replaced with
  `bootstrap --recover-from` (see the Phase A execution record).
- Cilium 1.16.2 predates k8s 1.36 support — the Cilium upgrade is a
  prerequisite of the k8s phase, not something bundled into it.
- k8s 1.37 requires Talos ≥ 1.14 (v1.13 tops out at 1.36); the control-plane
  upgrade path cannot skip minors: 1.35 → 1.36 → 1.37.

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

### Phase B — Kubernetes bump (rewritten post-incident, 2026-09-04)

> Executed 2026-09-04 (1.35.0 → 1.36.4, Cilium 1.16.2 → 1.20.1); the
> step-by-step procedure now lives in
> [`docs/runbooks/k8s-upgrade.md`](../runbooks/k8s-upgrade.md) — consult and
> extend that file for future bumps. The steps below record the decision and
> its rationale.

Every step below follows the incident lessons: snapshot first, one change at
a time, verify the derived state (routes, providerIDs, pod paths) after each
step, and let controllers converge before intervening manually.

1. **B0 — preconditions**: fresh `talosctl etcd snapshot` to
   `~/etcd-snapshots/` (hash-verified) — this is now the *primary* rollback
   primitive, not a last resort (proven: 66 MB restore in minutes). Confirm
   the cluster is converged first: all nodes Ready with correct
   `hcloud://` providerIDs, 3 Hetzner routes present, 0 CrashLoops, ArgoCD
   synced. If the etcd-snapshot CronJob automation is in place (INF-13),
   this step is a read of the newest backup.
2. **Cilium upgrade, own change** (1.16.2 → ≥1.18, matrix-checked against
   1.36). Verify the socketLB contract from AGENTS.md survives the chart bump
   (`bpf.socketLB.hostNamespaceOnly` renders — the helm-values lesson), then
   verify connectivity with a **workload-path probe**, not health endpoints:
   throwaway busybox pod → `nslookup` via the *real* ClusterIP (this cluster
   is `10.0.8.10`, not a 10.96 default) + cross-node `wget` to a pod IP.
   HostNetwork paths (API server) succeeding proves nothing about the pod
   network (recovery addendum).
3. **Gate verification, read-only**: check WEP-0005 gate names against 1.36's
   API surface *against the live cluster* — expected outcome is "no gates are
   live" (branch-only), i.e. nothing to change. If a correction were ever
   needed: it goes into `hetzner.tf`'s `kube_api_extra_args` (front door) and
   the CP is drained + tainted + replaced with `bootstrap --recover-from` —
   never `apply-config`.
4. **`talosctl upgrade-k8s --to 1.36.x`** (control-plane components only —
   not machine config, so it's inside the rules). Retry on the known
   `registry.k8s.io` 403 flake before diagnosing. After: `talosctl health`,
   node versions, pod sweep, and the workload-path probe again (the CCM's
   route state is the most likely casualty of any controller restart churn).
5. **Talos 1.14 bump** (prerequisite for 1.37, separate change):
   CP in-place via the schematic installer image (the 1.13→1.14 path is not
   the legacy path that rewrote cmdline, but **verify kernel args + machine
   config doc count after every node upgrade** — `read /proc/cmdline` and
   the config document list); workers via drain + taint + replace, one at a
   time (contiguous-id constraint). After each replacement: node Ready,
   providerID is the *current* server (`hcloud://` + real ID — the CCM has
   stamped a destroyed server's ID from a stale cache), route for the new
   podCIDR exists, kubelet re-registered (restart the kubelet service if the
   node object was deleted mid-run — kubelets register at startup only).
6. **`talosctl upgrade-k8s --to 1.37.x`** — same ritual as step 4.

### Phase C — verify (with the triage checklist)

- `talosctl health`; ArgoCD synced; restart counters flat.
- Connectivity by workload path, not health probes: busybox pod → DNS via
  ClusterIP, cross-node pod-to-pod TCP (HTTP health ports, e.g. coredns
  `:8080`), ClusterIP TCP (API server via service name).
- Infrastructure derived state: 3 Hetzner routes match the live podCIDRs
  (`GET /v1/networks/{id}`), all node providerIDs resolve to running servers,
  machine configs are single-v1alpha1 documents with intact
  `network.interfaces` and kernel args.
- The etcd snapshot taken in B0 becomes the canonical rollback point for
  this change; the next snapshot closes the loop.

## Consequences

- Rollback paths: `talosctl rollback` (CP, in-place), hcloud snapshot restore
  (last resort = DR drill, which INF-13 requires anyway).
- `registry.k8s.io` 403s from Hetzner ranges are a known flake
  (hcloud-talos#46) — retry `upgrade-k8s` before diagnosing.
- The hetzner.tf `talos_version` bump deliberately LAGS the packer build:
  its image data source selects the newest `os=talos` snapshot, so pushing
  the version bump before the build exists would fail the TFC apply.

## Phase A execution record (2026-09-03/04)

What actually happened, for the runbook's benefit:

- The in-place path hit the known 1.12→1.13 legacy-upgrade pitfall: the legacy
  installer rewrote the kernel cmdline (`talos.platform=metal` on a Hetzner
  host) and dropped custom args/hostname. Follow-up out-of-band config surgery
  (`talosctl patch mc`/`apply-config`) then corrupted the machine configs —
  multi-document duplication, a dropped `network.interfaces` section, hostname
  conflicts — cascading into a private-network blackout and hcloud-CCM
  node-deletion loops.
- Recovery executed for real, and it was cheap: the pre-upgrade etcd snapshot
  (66 MB, hash-verified) → CP server tainted and replaced via TFC →
  `talosctl bootstrap --recover-from <snapshot>` restored full etcd state in
  minutes. Workers replaced the same way (taint + TFC, contiguous ids). This
  is the "DR drill" INF-13 asked for, executed as the primary repair path.
- Binding rule landed in `verify-infra-change/SKILL.md`: machine configs are
  provision-time state; no out-of-band patching; live changes are
  drain + taint + replace; the control plane is cheaper to replace than to
  patch given `bootstrap --recover-from`.
- Deviations: node names reverted to module-canonical `control-plane-1` /
  `worker-1..2` (custom hostnames have no module input — one of the
  motivations for the Omni evaluation in WEP-0010); worker-3 retired
  (`worker_nodes = [1, 2]`).
- Phase B (k8s bump) still pending.

### Recovery completion addendum (2026-09-04)

The recovery's endgame surfaced derived-state cascades worth recording:

- The restored node objects carried dead providerIDs → hcloud-CCM deletion
  loop → its route controller deleted the Hetzner network route for the CP's
  podCIDR → cross-node pod traffic (all protocols) blackholed, while
  hostNetwork paths (API server) kept "working" over the underlay — a
  deceptive signal. Route repaired via the hcloud API
  (`POST /networks/{id}/actions/add_route`), then kept by the CCM.
- Kubelets register at startup only: the CP's deleted node object orphaned
  the kubelet until `talosctl service kubelet restart` re-registered it.
- The CCM stamped a destroyed server's providerID from a stale server list;
  a fresh registration stamped the right one. Node objects are derived
  state — recreate, never patch (`providerID` patches are API-forbidden).
- The etcd restore also rolled back config drift (the Cilium ConfigMap's
  out-of-band tunnel-mode values reverted to the repo's native-routing
  values) — an accidental benefit of snapshot-based recovery.
- `bootstrap --recover-from` takes a client-side local file path and streams
  it over the Talos API (URL-form arguments fail).
- The mcp-token-vault CrashLoop (Supabase-reset fallout: `token_vault` role
  password-auth mismatch) self-resolved after restart cycles; no manual DB
  repair was needed — let the bootstrap/retry paths converge before
  intervening.

### Phase B execution record (2026-09-04)

- B0: etcd snapshot (66 MB, sha256 8401bc77…) + full convergence check
  (3/3 nodes Ready, correct providerIDs, 3 routes, 0 CrashLoops).
- Cilium: the upgrade guide allows **consecutive minors only** — executed as
  four chart-bump hops via ArgoCD (1.16.2 → 1.17.18 → 1.18.12 → 1.19.7 →
  1.20.1; 1.20 is the first line e2e-testing k8s 1.36). Discovery: the
  cilium chart ships **no CRDs** (and no `crds:` helm value) in any of these
  versions — the **cilium-operator applies and updates CRDs itself at
  startup** (`apis.createCRDs` hook), so no manual CRD steps exist. The
  1.20 preflight CNP validator caught `deny-by-default` (empty spec now
  rejected); fixed with explicit `ingress: []`/`egress: []` (semantics
  unchanged). Post-rollout: workload-path probes green; tailscale LB path
  needs a device-side check (the 1.20 socketLB-NodePort behavior change).
- Gate verification: no feature-gates flag on the live apiserver — no-op.
- `upgrade-k8s --to 1.36.4`: the command derives the kube API endpoint from
  the Talos config (`kube.cluster.local`), which is node-only — from a
  workstation use `--endpoint https://5.75.173.162:6443`. First run updated
  all components + kubelets but failed the manifest dry-runs against the
  apiserver **mid-restart** (a kubescape ValidatingAdmissionPolicy could not
  resolve its paramKind during the rollout window and denied everything it
  binds); the idempotent re-run completed cleanly. Nodes: 3/3 v1.36.4.
- Remaining: Talos 1.14 bump, then `upgrade-k8s --to 1.37.x`.
