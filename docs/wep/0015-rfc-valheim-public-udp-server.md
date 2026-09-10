# WEP-0015: Valheim dedicated server — first public UDP workload

**Type:** RFC · **Status:** Accepted (2026-09-10) · **Date:** 2026-09-10

## Context

Valheim 1.0 is out and we want a dedicated server in the de/hetzner cluster for
a playthrough. Every existing workload in the cluster is either HTTP (Envoy
Gateway, tailnet-only) or internal (ClusterIP). A Valheim dedicated server needs:

1. **Public UDP ingress** on ports 2456 (game), 2457 (Steam query), and 2458
   (crossplay backend) — players connect directly from the internet, not through
   a tailnet or HTTP reverse proxy.
2. **Persistent world saves** — PVC-backed storage that survives pod restarts.
3. **More CPU/RAM than the CX23 nodes provide** — the server binary idles at
   ~2.8 GB RSS and the playthrough group wants 4 dedicated cores.

The cluster has no mechanism for public UDP exposure today. The only
`type: LoadBalancer` Service uses `loadBalancerClass: tailscale` (CGNAT IP,
tailnet-only). Envoy Gateway is HTTP/HTTPS-only. `hostNetwork` is blocked by CEL
admission policies. The hcloud CCM is running (deployed by the hcloud-talos
module) but has never been used to provision a LoadBalancer.

## Decision

1. **Node bump** (`terraform/hetzner.tf`): worker-2 upgraded from CX23 (2 vCPU /
   4 GB) to CX33 (4 vCPU / 8 GB, ~€11/mo). The Valheim StatefulSet pins to this
   node via `nodeSelector: node.kubernetes.io/instance-type: cx33` (label added
   by hcloud CCM). Worker-1 stays CX23 — the lightweight co-located workloads
   (hermes, mcp-token-vault, etc.) fit comfortably there.

2. **hcloud LoadBalancer** (`apps/valheim/service.yaml`): a `type: LoadBalancer`
   Service with no `loadBalancerClass` — the hcloud CCM reconciles it and
   provisions a Hetzner Cloud Load Balancer (type lb11, location nbg1) with a
   public IP.    `externalTrafficPolicy: Local` preserves client source IPs (no
   SNAT) and restricts forwarding to nodes running the pod. UDP ports 2456, 2457,
   and 2458 (crossplay).

3. **ExternalDNS `service` source** (`apps/external-dns/values.yaml`): add
   `service` to the sources list. ExternalDNS creates a DNS-only A record for
   `valheim.willpxxr.com` pointing at the LB's public IP, driven by the
   `external-dns.alpha.kubernetes.io/hostname` annotation on the Service.
   Safe with existing workloads: without `--fqdn-template`, ExternalDNS only
   creates records for Services carrying the hostname annotation — the Tailscale
   LoadBalancer in envoy-gateway-system doesn't have it and is skipped.

4. **Network policy** (`apps/valheim/network-policy.yaml`): default-deny with
   public UDP ingress on 2456/2457/2458 (`fromEntities: world`), DNS egress, and
   Steam egress (TCP 443 for API/content + UDP 27000-27031 for Steam backend —
   IPs not enumerable). First workload with public ingress in the cluster.

5. **Server image**: `ghcr.io/community-valheim-tools/valheim-server:v1.2.0`
   (community-valheim-tools fork of lloesche/valheim-server, the standard
   Valheim Docker image). `SERVER_PUBLIC=false` — private server, join by IP or
   `valheim.willpxxr.com`. `CROSSPLAY=true` — enables PlayFab matchmaking so
   PS5/Xbox/Microsoft Store clients can join alongside Steam. Crossplay opens a
   third UDP port (2458) for the crossplay backend.

6. **Password via 1Password** (`terraform/valheim.tf` + `apps/valheim/externalsecret.yaml`):
   `random_password` generates a 24-char password, written to 1Password by
   Terraform — same pattern as the ArgoCD redis auth (`terraform/argocd.tf`). No
   manual paste needed; the ExternalSecret syncs it into the cluster.

7. **Persistent storage**: 10 Gi PVC (`hcloud-volumes` StorageClass) mounted at
   `/config` (world saves, backups, server config) and `/opt/valheim` (the
   downloaded server binary, ~1 GB — mounted via `subPath: server` so the two
   directory trees don't overlap on the same volume). StatefulSet with
   `volumeClaimTemplates`.

8. **CEL MutatingAdmissionPolicy for topology spread**
   (`apps/cel-admission-policies/mutating-policies.yaml`): a
   `MutatingAdmissionPolicy` that injects `topologySpreadConstraints`
   (`maxSkew: 1`, `topologyKey: kubernetes.io/hostname`,
   `whenUnsatisfiable: ScheduleAnyway`) into pods at admission time, using
   `app.kubernetes.io/name` as the `labelSelector`. This fixes the issue where
   multi-replica workloads (e.g. the Tailscale ProxyGroup ingress pods) all
   landed on the same node. `ScheduleAnyway` (not `DoNotSchedule`) is used
   because with only 2 worker nodes, a hard constraint would block pod
   rescheduling during single-node outages. Pods that already have hostname-
   based TSC are left alone. kube-system is excluded (DaemonSets don't need it).

## Convergence

Single push to `main` — no phased migration needed:

- **Terraform apply** (TFC): replaces worker-2 with CX33 (existing workloads on
  worker-2 reschedule to worker-1 during the replacement), creates the
  `valheim` 1Password item. Note: the previous CPX42 → CX33 type change requires
  a resource taint (destroy + recreate) since Hetzner can't shrink disks — do
  this via TFC's "mark for replacement" UI.
- **ArgoCD sync**: creates the valheim namespace, CEL MutatingAdmissionPolicy
  (topology spread), network policy, ExternalSecret, StatefulSet, and
  LoadBalancer Service. The StatefulSet may initially be Pending until the CX33
  node registers; ArgoCD's retry policy (5 retries, exponential backoff) handles
  this. Existing multi-replica pods (Tailscale ProxyGroup) will spread on next
  recreation.
- The hcloud CCM provisions the LoadBalancer and assigns a public IP.
  ExternalDNS sees the IP via the `service` source and creates the
  `valheim.willpxxr.com` A record.

The 1Password item is populated by Terraform (`random_password` resource) on the
first apply — no manual paste needed. The ExternalSecret syncs it into the cluster
on its next refresh (or force-sync).

## Risks / rollback

- **Node replacement**: bumping worker-2's type triggers a TFC replace — the
  old server is destroyed and a new one created. Workloads on worker-2 are
  rescheduled to worker-1 (CX23) during the gap. If worker-1 can't absorb them,
  some pods stay Pending until the new CX33 node joins. Rollback: revert the
  type change in `hetzner.tf`.
- **hcloud LB cost**: type lb11 is ~€4.50/mo + traffic. Not prohibitive but the
  first recurring LB cost in the cluster.
- **MutatingAdmissionPolicy**: if the policy is misconfigured, pod creation in
  non-kube-system namespaces fails (failurePolicy: Fail). The `has-app-name-label`
  matchCondition ensures pods without `app.kubernetes.io/name` are skipped. The
  `no-existing-tsc` matchCondition ensures workloads with their own TSC are
  left alone. Verify with `kubectl get pods -A -o wide` after sync to confirm
  spreading.
- **ExternalDNS scope expansion**: adding `service` to ExternalDNS sources
  broadens what it watches. The hostname-annotation gate prevents unintended
  records, but if a future LoadBalancer Service gets the annotation by
  accident, ExternalDNS will create a record for it.
- Rollback is `git revert` — ArgoCD prunes the app, the LB and DNS record are
  deleted (ExternalDNS `upsert-only` won't delete, so the DNS record needs
  manual cleanup); revert the Terraform changes to downsize the node.

## What's not included

- **Mods** (BepInEx / ValheimPlus): not enabled. Can be added via env vars
