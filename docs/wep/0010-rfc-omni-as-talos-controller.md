# WEP-0010: Evaluate Omni as the Talos controller

**Status**: draft — for discussion
**Type**: RFC
**Related**: WEP-0009 (upgrade strategy), INF-13

## Summary

Terraform + `user_data` gives this cluster provision-time config only: there is
no declarative front door for live-node machine-config changes, and the ad-hoc
alternative (`talosctl patch mc` on live nodes) just caused a full etcd
recovery (2026-09-03/04). Sidero's [Omni](https://omni.sidero.dev) is a
management plane that owns Talos machine configs declaratively — versioned
config patches applied **in place**, drift-detected — and drives Talos and
Kubernetes upgrades natively. This WEP proposes a time-boxed evaluation before
Phase B of WEP-0009, since Phase B/C are exactly the kind of repeated in-place
operations Omni exists to manage.

## Why now

- The incident showed the cost of the current model: every config change is
  either "future re-provisions only" (module inputs) or hand-run surgery.
- WEP-0009 Phase B needs `upgrade-k8s`, Cilium coordination, and possibly
  kernel-arg fixes — all manual today, and all repeated for 1.37.
- Worker/CP replacement (taint + replace + recover-from) works but is a
  workaround for missing config lifecycle, not a design.

## What Omni would change

- **Config**: patches live in git, synced via `omnictl` or the Omni Terraform
  provider, applied in place with drift detection — keeps "Git ships, hands
  don't" while restoring in-place capability (Talos supports it; our IaC
  currently doesn't).
- **Upgrades**: a cluster template (`talosVersion`, `kubernetesVersion`,
  patches) — Omni drives etcd-safe rolling upgrades; WEP-0009's runbooks
  collapse into template syncs.
- **IaC split**: Terraform keeps Hetzner server lifecycle (Omni TF provider
  machine requests, or omnictl enrollment of TF-created servers); Omni owns
  config.
- **Recovery**: Omni handles etcd member replacement/join natively, replacing
  the manual snapshot choreography.

## Costs / risks (to verify during the spike)

- Another control plane: self-hosted Omni needs its own VM + object storage
  (ops burden), vs Omni Cloud (paid SaaS) — pick one.
- Migration cost: re-enrollment/re-provision of all nodes once. Cheap here
  (single CP + 2 workers, proven `bootstrap --recover-from`).
- **Hetzner machine-request support and the exact Omni TF-provider surface
  are unverified** — Omni's docs were unreachable when this was written;
  confirm before the spike.
- New failure domain: Omni availability gates config changes and upgrades
  (not day-2 operation of a running cluster).

## Proposal

1. Spike (time-boxed): self-hosted Omni on a small hcloud VM (or Omni Cloud
   trial), enroll one throwaway worker; exercise in-place config patch,
   Talos upgrade, and node replacement.
2. Compare against WEP-0009's manual runbooks for the Phase B operations.
3. Decide: migrate `de/hetzner` (one re-provision cycle) or stay TF-native
   with the SKILL.md taint+replace discipline.

## Consequences

- **Adopted**: WEP-0009's manual paths become Omni template syncs;
  `hetzner.tf` slims to server lifecycle; the SKILL.md machine-config rule
  restates as "patches go through Omni, never the node".
- **Rejected**: document why here; the taint+replace discipline remains the
  front door.
