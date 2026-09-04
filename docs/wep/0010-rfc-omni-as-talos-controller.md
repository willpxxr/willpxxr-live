# WEP-0010: Evaluate Omni as the Talos controller

**Status**: rejected 2026-09-04 — see Decision at the end
**Type**: RFC
**Related**: WEP-0009 (upgrade strategy), WEP-0011 (Cilium → ArgoCD), INF-13

## Summary

Terraform + the hcloud-talos module gives this cluster provision-time config
only: there is no declarative front door for live-node machine-config
changes, and the ad-hoc alternative (`talosctl patch mc`) caused the
2026-09-03/04 etcd-recovery incident. Omni (Sidero Labs) is a continuously-
reconciling control plane for Talos clusters — the Kubernetes-of-cluster-
management model (declarative API, etcd-backed state, controllers) — and it
directly targets every gap we hit.

## What Omni gives over TF + the module (verified against docs)

- **In-place config as patches**: machine config changes are declarative
  patches, applied and continuously reconciled in place — drift is detected,
  not discovered. Kills the taint+replace necessity for config changes.
- **Cluster templates**: multi-doc YAML declaring cluster, talosVersion,
  kubernetesVersion, machine sets, patches. `omnictl cluster template sync`
  reconciles — Talos *and* k8s upgrades become template field changes with
  etcd-safe rolling orchestration. WEP-0009's runbook (§0–§5) collapses into
  the template + a sync.
- **Node lifecycle**: machine classes / explicit UUIDs; join, replace,
  scale, decommission are reconciled operations. Built-in etcd backup/restore
  story (documented template-managed restore).
- **SideroLink management plane**: nodes connect to Omni over WireGuard;
  Omni proxies the kube-apiserver (k8s proxy) — a stable, firewall-friendly
  management path and the option to stop exposing the API publicly.
- **GitOps-native**: templates in git + apply-only CI (`omnictl cluster
  template sync`) is the documented recommended flow — matches "Git ships,
  hands don't". (Not ArgoCD-style two-way sync; ArgoCD itself stays
  untouched for the app layer.)
- **Auth0 integration** built in (`--auth-auth0-enabled`), omnictl + UI +
  a Terraform provider (alpha; prefer omnictl for now).

## Verified costs / facts

- **License**: self-hosted Omni is BSL 1.1 — free for non-production;
  production self-hosting requires a Sidero contract.
- **Pricing**: **Omni Hobby (SaaS): $10/mo — 10 nodes, 1 user,
  non-commercial** (explicitly "Running a homelab?"). Business tier is
  $100/node/mo with a 10-node minimum (irrelevant here).
- **Self-hosted footprint**: Docker host, 2 vCPU/4 GB, ports 443/8090/8091/
  8100/5556/50180-udp, TLS (cfssl), GPG key for etcd-at-rest, Dex or direct
  Auth0, embedded etcd (or external for HA).
- **TF provider is early alpha** — for Omni resources use omnictl/templates;
  TF keeps provisioning the raw infra (network, servers, DNS).

## Migration (non-disruptive import path)

1. Stand up Omni (Hobby SaaS, or self-host on a small hcloud VM).
2. **`omnictl import`**: connects the EXISTING cluster without disruption —
   discovers state, validates health, zips a backup of all machine configs,
   wires nodes to Omni (SideroLink), and registers the cluster as **locked**
   until verified. Existing customizations are preserved as **config
   patches** (diff of Omni's default vs live config). Our nodes boot
   factory-schematic installers (WEP-0009) — the schematic is detected and
   reused, so upgrade continuity holds.
3. `omnictl cluster template export` → commit the template to git
   (`gitops/clusters/de/hetzner/omni/cluster-template.yaml`) — it becomes
   the authoritative cluster definition.
4. Verify workloads, then unlock. From here: config/version changes are
   template edits + sync.
5. **Slim `hetzner.tf`**: TF keeps network/firewall/DNS and server
   lifecycle; the module's config/bootstrap/CNI roles move to Omni
   (`deploy_cilium` already false per WEP-0011). New-node flow: TF (or an
   Omni machine class) creates the server, Omni enrolls and reconciles it
   into the cluster.
6. CI: an apply-only GitHub Action running `omnictl cluster template sync`
   on changes to the template path.
7. Cleanup: the talos-CCM's CSR-approval role is subsumed by Omni's node
   identity handling; the hcloud-CCM stays (routes/LB are Hetzner-specific).

## Recommendation

Adopt via the **Omni Hobby SaaS ($10/mo)** for the least operational burden,
or self-host on a small VM if data- locality of the management plane
matters (free for non-commercial homelab use under the BSL). Either way:
migrate by import (no rebuild), move config/version authority to a git-
synced cluster template, and reduce the TF module to infrastructure-only.
Time-box: the import + export + unlock is an evening, given tonight's
proven recovery path as the fallback.

## Consequences

- WEP-0009's manual upgrade paths become template syncs; the runbook keeps
  its value for the migration window and for Omni-outage scenarios.
- `hetzner.tf` slims to infra; `verify-infra-change` gains an omnictl/
  template verification step (render/validate the template before sync).
- If rejected: the taint+replace discipline remains the front door, and this
  WEP records why.

## Decision (2026-09-04): rejected

Not worth it at this scale. The cluster is 3 nodes; the upgrade runbook is
now written down and was executed end-to-end successfully the same day
(Cilium 1.16.2 → 1.20.1 + k8s 1.36.4); recovery is proven and cheap
(`bootstrap --recover-from`). Against that: $10/mo recurring, a second
control plane to run/patch/backup (self-host) or a dependency on Sidero's
SaaS, an apply-only (non-two-way) GitOps flow for the cluster layer, and a
migration + de-module ceremony. Revisit if the cluster grows past what one
runbook can hold, or if in-place config changes become frequent enough that
taint+replace stops being acceptable.
