# WEP-0015: Valheim dedicated server — first public UDP workload

**Type:** RFC · **Status:** Accepted (2026-09-10) · **Date:** 2026-09-10

## Context

Valheim 1.0 is out and we want a dedicated server in the de/hetzner cluster for
a playthrough. Every existing workload in the cluster is either HTTP (Envoy
Gateway, tailnet-only) or internal (ClusterIP). A Valheim dedicated server needs:

1. **Public UDP ingress** — players connect directly from the internet, not
   through a tailnet or HTTP reverse proxy.
2. **Persistent world saves** — PVC-backed storage that survives pod restarts.
3. **More CPU/RAM than the CX23 nodes provide** — the server binary idles at
   ~2.8 GB RSS and the playthrough group wants dedicated cores.

The cluster has no mechanism for public UDP exposure today. The only
`type: LoadBalancer` Service uses `loadBalancerClass: tailscale` (CGNAT IP,
tailnet-only). Envoy Gateway is HTTP/HTTPS-only. `hostNetwork` is blocked by CEL
admission policies. An hcloud LoadBalancer (~€9/mo) was considered and rejected
in favour of NodePort to avoid the recurring LB cost.

## Decision

1. **Node bump** (`terraform/hetzner.tf`): worker-2 upgraded from CX23 (2 vCPU /
   4 GB) to CX33 (4 vCPU / 8 GB, ~€11/mo). The Valheim StatefulSet pins to this
   node via `nodeSelector: node.kubernetes.io/instance-type: cx33` (label added
   by hcloud CCM). Worker-1 stays CX23 — the lightweight co-located workloads
   (hermes, mcp-token-vault, etc.) fit comfortably there.

2. **NodePort Service** (`apps/valheim/service.yaml`): a `type: NodePort`
   Service with `externalTrafficPolicy: Local` (preserves client source IPs, no
   SNAT). `SERVER_PORT=32456` in the container so the game server listens on
   32456-32458, matching the NodePort values exactly — this is important for
   crossplay, since PlayFab advertises the port the server reports and players
   must reach it directly. No LoadBalancer, no recurring LB cost.

3. **Firewall** (`terraform/hetzner.tf`, module's `extra_firewall_rules`): opens
   UDP 32456-32458 inbound on all nodes via the hcloud firewall that the
   hcloud-talos module manages. `externalTrafficPolicy: Local` ensures only the
   node running the pod forwards traffic, but the firewall rule is cluster-wide
   (the module doesn't support per-node rules).

4. **DNS** (`apps/external-dns/values.yaml` + Service annotation): ExternalDNS
   `service` source creates a DNS-only A record for `valheim.willpxxr.com`
   from the `external-dns.alpha.kubernetes.io/hostname` annotation on the
   NodePort Service. `externalTrafficPolicy: Local` ensures ExternalDNS only
   publishes the IP of the node running the pod (not all nodes). If the pod
   moves nodes, DNS updates on the next ExternalDNS sync (1m interval).

5. **Network policy** (`apps/valheim/network-policy.yaml`): default-deny with
   public UDP ingress on 32456/32457/32458 (`fromEntities: world`), DNS egress,
   and Steam egress (TCP 443 for API/content + UDP 27000-27031 for Steam backend
   — IPs not enumerable). First workload with public ingress in the cluster.

6. **Server image**: `ghcr.io/community-valheim-tools/valheim-server:v1.2.0`
   (community-valheim-tools fork of lloesche/valheim-server, the standard
   Valheim Docker image). `SERVER_PUBLIC=false` — private server, join by IP or
   `valheim.willpxxr.com:32456`. `CROSSPLAY=true` — enables PlayFab matchmaking
   so PS5/Xbox/Microsoft Store clients can join alongside Steam.

7. **Password via 1Password** (`terraform/valheim.tf` + `apps/valheim/externalsecret.yaml`):
   `random_password` generates a 24-char password, written to 1Password by
   Terraform — same pattern as the ArgoCD redis auth (`terraform/argocd.tf`). No
   manual paste needed; the ExternalSecret syncs it into the cluster.

8. **Persistent storage**: 10 Gi PVC (`hcloud-volumes` StorageClass) mounted at
   `/config` (world saves, backups, server config) and `/opt/valheim` (the
   downloaded server binary, ~1 GB — mounted via `subPath: server` so the two
   directory trees don't overlap on the same volume). StatefulSet with
   `volumeClaimTemplates`.

9. **CEL MutatingAdmissionPolicy for topology spread**
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
  `valheim` 1Password item, opens firewall ports 32456-32458. Note: the
  previous CPX42 → CX33 type change requires a resource taint (destroy +
  recreate) since Hetzner can't shrink disks — do this via TFC's "mark for
  replacement" UI.
- **ArgoCD sync**: creates the valheim namespace, CEL MutatingAdmissionPolicy
  (topology spread), network policy, ExternalSecret, StatefulSet, and NodePort
  Service. The StatefulSet may initially be Pending until the CX33 node
  registers; ArgoCD's retry policy (5 retries, exponential backoff) handles
  this. Existing multi-replica pods (Tailscale ProxyGroup) will spread on next
  recreation.
- **ExternalDNS** sees the NodePort Service's hostname annotation and creates
  `valheim.willpxxr.com` pointing at the node running the pod (worker-2).

The 1Password item is populated by Terraform (`random_password` resource) on the
first apply — no manual paste needed. The ExternalSecret syncs it into the cluster
on its next refresh (or force-sync).

Players connect via `valheim.willpxxr.com:32456` (Steam) or the crossplay server
browser (PS5/Xbox).

## Risks / rollback

- **Node replacement**: bumping worker-2's type triggers a TFC replace — the
  old server is destroyed and a new one created. Workloads on worker-2 are
  rescheduled to worker-1 (CX23) during the gap. If worker-1 can't absorb them,
  some pods stay Pending until the new CX33 node joins. ExternalDNS updates
  `valheim.willpxxr.com` automatically once the pod reschedules to the new node.
  Rollback: revert the type change in `hetzner.tf`.
- **NodePort port number**: players must specify the port (32456) when joining
  via Steam. Crossplay (PlayFab) advertises the port automatically. The
  non-standard port is a tradeoff for avoiding the LB cost.
- **MutatingAdmissionPolicy**: if the policy is misconfigured, pod creation in
  non-kube-system namespaces fails (failurePolicy: Fail). The `has-app-name-label`
  matchCondition ensures pods without `app.kubernetes.io/name` are skipped. The
  `no-existing-tsc` matchCondition ensures workloads with their own TSC are
  left alone. Verify with `kubectl get pods -A -o wide` after sync to confirm
  spreading.
- Rollback is `git revert` — ArgoCD prunes the app; revert the Terraform changes
  to downsize the node, remove the DNS record, and close the firewall ports.

## What's not included

- **Mods** (BepInEx / ValheimPlus): not enabled. Can be added via env vars
  without changing manifests.
