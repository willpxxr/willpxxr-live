# ADR-0007: Tailscale ExtensionServiceConfig for worker nodes

**Date:** 2026-09-03 · **Status:** Accepted

## Context

2026-09-01→03 incident: both workers cycled through `NodeNotReady` roughly
hourly (63+ flaps since 08-30), and every container on each worker was killed
at once (`Unknown exit=255`, kubelet `SandboxChanged`) — producing the
five-digit restart counts across the whole workload fleet
(`cilium-envoy` at 1369, `hubble-ui` at 2072). Kubernetes kept showing the
nodes Ready throughout, masking the real state.

Root cause chain:

- The `ext-tailscale` system extension (v1.92.3, baked into the Packer
  schematic) declares `depends: configuration: true`. It refuses to start
  until it receives an `ExtensionServiceConfig` machine-config document
  (`name: tailscale`, `environment: [TS_AUTHKEY=...]`).
- The `hcloud-talos` module only appends its `tailscale_config_patch` to the
  **control-plane** `config_patches` (talos.tf, control-plane concat vs.
  worker concat) — verified at v3.4.9, v3.4.15 and current main. Worker
  machine configs therefore never contained the document, on any 3.x this
  repo could have resolved since the 2026-06-27 provisioning (7cbccd3).
- With the dependency unsatisfied, `startAllServices` blocks forever and the
  machine never leaves the BOOTING stage. kubelet/apid run regardless, so the
  node heartbeats and reports Ready; the machines were then hard-reset at
  irregular 20–70 min intervals (no Reboot RPC, no panic, no OOM in the
  captured logs — hypervisor/watchdog-class reset of the half-booted machine).

The `tailscale.auth_key` input in `hetzner.tf` was declared and the key
resource minted from day one, but was inert for workers the entire life of
the cluster.

## Decision

1. **Future nodes:** add `talos_worker_extra_config_patches` to the
   `hcloud-talos` module block in `hetzner.tf`, carrying the same
   `ExtensionServiceConfig` document with
   `TS_AUTHKEY=${tailscale_tailnet_key.cluster_nodes.key}`.
2. **Live nodes:** per the `verify-infra-change` §1 gotcha (machine config
   never reaches provisioned nodes — `user_data` is under
   `lifecycle.ignore_changes`), landing this on the existing workers requires
   the one-time `talosctl patch mc --config-patch` + `reboot` runbook,
   WEP-0005 precedent. The auth key is pulled from TFC state into a temp file
   and shredded after; never shell history or Git. The control plane already
   received the document from the module and is unaffected (zero restarts
   there corroborated the split).

## Consequences

- Future worker re-provisions boot to the RUNNING stage with the extension
  active; nodes join the tailnet as originally intended by the 7cbccd3
  design.
- Any Talos version bump must re-verify the extension's configuration
  contract (extension majors have changed it before; the config-dependency
  behavior is exactly what silently broke this cluster) — same discipline as
  WEP-0005's feature-gate re-check.
- Worth an upstream issue/PR: appending `tailscale_config_patch` to the
  worker `config_patches` in `talos.tf` fixes this for every consumer of the
  module.
