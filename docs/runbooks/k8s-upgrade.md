# Runbook: Kubernetes version upgrade (Talos on Hetzner)

Distilled from the 2026-09-04 Phase B execution (WEP-0009) — 1.35.0 → 1.36.4
with Cilium 1.16.2 → 1.20.1. Next due: **1.36.4 → 1.37.x** (requires the
Talos 1.14 bump first — see §0).

Conventions: live cluster state changes go through the front doors named
below. Machine configs are provision-time state — never patch them on live
nodes (see `verify-infra-change` skill).

## 0. Prerequisite ladder (check before every bump)

| k8s target | Requires | Verified source |
|---|---|---|
| 1.36.x | Talos 1.13.x, Cilium ≥ 1.20 (1.19 tops out at 1.35) | cilium docs compatibility page |
| 1.37.x | **Talos 1.14 first** (`hetzner.tf` talos_version + packer default + CI snapshot build), then Cilium ≥ 1.21 (verify matrix) | talos support matrix, cilium compatibility |

Talos bumps: control plane in-place via the schematic installer image
(`factory.talos.dev/installer/7d4c31cb…:v1.14.x`) — **verify kernel args and
machine config doc count after every node upgrade** (`talosctl read
/proc/cmdline`); workers via drain + `terraform taint` + any `.tf` push
(one at a time; contiguous ids).

## 1. Preconditions (B0)

```sh
# Snapshot + hash (the proven rollback primitive)
talosctl -n 10.0.1.101 etcd snapshot ~/etcd-snapshots/etcd-pre-<version>-$(date +%F).snapshot
sha256sum ~/etcd-snapshots/etcd-pre-<version>-*.snapshot

# Convergence gate — all must be green before touching anything
kubectl get nodes -o wide                       # 3/3 Ready, correct versions
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.providerID}{"\n"}{end}'
#   → hcloud://<id> for every node, ids resolve to RUNNING servers (the CCM
#     has stamped destroyed servers from a stale cache before)
TOK=$(kubectl -n kube-system get secret hcloud -o jsonpath='{.data.token}' | base64 -d)
curl -s -H "Authorization: bearer $TOK" https://api.hetzner.cloud/v1/networks/12378981 \
  | python3 -c "import json,sys; [print(r) for r in json.load(sys.stdin)['network']['routes']]"
#   → 3 routes, one per node podCIDR (a missing one = cross-node blackhole;
#     see the recovery addendum in WEP-0009)
kubectl get po -A | grep -cEv 'Running|Completed'   # expect 0
kubectl -n argocd get app                           # expect all Synced
```

## 2. Cilium first, as its own change

Consecutive minor hops **only** (cilium upgrade guide; no skipping). Each hop
is one commit: bump `version:` in `apps/cilium/app.yaml`, keep
`values.yaml` otherwise untouched, push.

- **CRDs need nothing**: the chart ships no CRDs and has no `crds:` value —
  the **cilium-operator applies and updates CRDs at startup**
  (`apis.createCRDs` hook). Do not hand-apply CRDs.
- Keep `upgradeCompatibility` in values pinned to the cluster's *first-ever*
  cilium version (`1.16`).
- For hops with schema/behavior changes (e.g. 1.20), run the preflight first:

```sh
helm template cilium-preflight cilium/cilium --version <TARGET> --namespace kube-system \
  --set preflight.enabled=true --set agent=false --set operator.enabled=false \
  --set k8sServiceHost=127.0.0.1 --set k8sServicePort=7445 | kubectl apply -f -
kubectl -n kube-system logs deploy/cilium-pre-flight-check -c cnp-validator   # want: "All CCNPs and CNPs valid!"
kubectl -n kube-system delete ds cilium-pre-flight-check deploy cilium-pre-flight-check
```

- Per-hop verify: agents rolled (`kubectl -n kube-system get ds cilium -o
  jsonpath='{.spec.template.spec.containers[0].image}'`), pods Running 0
  restarts, `cilium status` modules OK, then a **workload-path** probe:

```sh
kubectl run hopcheck --image=busybox:1.36 --restart=Never --command -- sleep 180
kubectl exec hopcheck -- timeout 8 nslookup kubernetes.default.svc.cluster.local
# (delete it when done — Completed probes linger otherwise)
```

- HostNetwork targets (API server) succeed even when the pod network is
  broken — they prove nothing; probe pod IPs/ClusterIPs.
- After a 1.20+ hop: verify the tailscale LB path **from a tailnet device**
  (1.20 load-balances pod→NodePort at the client pod's egress even with
  `socketLB.hostNamespaceOnly` — the contract the tailscale proxies rely on
  moved; in-cluster probes cannot see this).

## 3. Gate check (read-only)

```sh
kubectl -n kube-system get po -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | grep -o 'feature-gates[^"]*'
```

No flag = nothing to migrate (current state). If gates appear: they live in
machine config → `hetzner.tf` `kube_api_extra_args` + CP taint + replace +
`bootstrap --recover-from` — **never `apply-config`**.

## 4. The bump

```sh
talosctl -n 10.0.1.101 upgrade-k8s --to <1.36.x-patch> --endpoint https://5.75.173.162:6443
```

- **`--endpoint` is required from a workstation**: the command derives the
  kube API endpoint from the Talos config (`kube.cluster.local:6443`), which
  only resolves on the nodes. The public endpoint (`5.75.173.162:6443`) is
  the laptop-reachable one.
- `registry.k8s.io` 403s from Hetzner ranges are a known flake — retry.
- **Manifest dry-runs can transiently fail against the apiserver
  mid-restart** (a kubescape ValidatingAdmissionPolicy denied everything it
  binds while its paramKind was unresolvable). The command is idempotent —
  re-run once the apiserver is stable before diagnosing anything.
- Verify: all nodes report the new version, coredns image bumped, pod sweep
  clean, ArgoCD synced.

## 5. Reconcile Terraform (future provisions)

Bump `hetzner.tf`'s `module.talos.kubernetes_version` (and the talos_version
pair when applicable) in the same session — otherwise the next node
replacement provisions at the old version. `terraform fmt` before pushing;
the plan is a no-op for existing nodes (`user_data` is ignored after
creation).

## 6. Close-out

- WEP-0009 gets a dated execution record (what actually happened).
- Keep the newest pre-bump snapshot; prune older ones deliberately, not
  automatically.
- Anything that needed a manual repair (routes, node objects, providerIDs)
  gets written back into this runbook — that's the whole point of it.
