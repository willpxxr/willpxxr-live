# WEP-0005 (RFC): Personal chat agent via kagent AgentHarness (hermes) on Agent Substrate

## Status

Accepted (2026-08-31) -- implementation staged in this commit; phases ship as
separate applies (see Plan).

## Context

We want a personal AI agent chatable from Telegram (Discord later), running on
the de/hetzner cluster. The chosen stack is **Hermes Agent**
(github.com/NousResearch/hermes-agent -- Nous Research's self-hosted agent with
a multi-platform messaging gateway) deployed through **kagent's AgentHarness**
(`kagent.dev/v1alpha2`, `spec.backend: hermes`), which provisions hermes
sandboxes on **Agent Substrate** (kagent's snapshot/restore actor runtime).

The user picked kagent+Substrate over a plain StatefulSet deploy of the hermes
container. That choice went *against* the initial research recommendation
(a single StatefulSet + PVC is the simpler primitive for one always-on agent),
so this RFC records both why the simpler path was passed over (platform value:
declarative harness CRs, kagent UI/chat surface, human-in-the-loop approvals,
substrate's snapshot/restore for future multi-agent work) and every assumption
that had to be verified against reality before committing, several of which
flipped during research:

- **"Snapshots are GCS-only"** -- true only of the *kagent AgentHarness CRD*
  (`AgentHarnessSubstrateSnapshotsConfig.location` has `Pattern: ^gs://`) and
  only when explicitly set. The substrate chart (0.0.21) **bundles an
  S3-compatible store (RustFS)** with the bucket pre-provisioned, so **no GCP
  dependency exists**. `atelet.storageBackend: s3` targets the bundled store.
- **"Substrate needs gVisor on the nodes"** -- false for our topology. Workers
  fetch `runsc` themselves via SandboxConfig (the kagent chart even carries
  the gvisor-release URLs); the substrate kind-based walkthrough runs on
  vanilla clusters. **No Talos image/machine changes for gVisor.** (The
  `siderolabs/gvisor` extension exists and is core-tier, but is not needed.)
- **"The kagent path needs no PVCs"** -- false at the platform layer: the
  substrate chart's bundled **postgres** (ateapi state) and **rustfs**
  (snapshots) both claim PVCs, and the cluster had **zero StorageClasses**
  (verified live). A CSI driver is a prerequisite after all.
- **"certificates.k8s.io/v1beta1 is available"** -- false: verified live, the
  API server serves only `certificates.k8s.io/v1`. The chart requires
  ClusterTrustBundle, ClusterTrustBundleProjection and PodCertificateRequest
  (all alpha on k8s 1.35; substrate's own kind script enables exactly this
  set, noting upstream doesn't default them "as of v1.36"). The
  `hcloud-talos` module (3.4.15) exposes `kube_api_extra_args` /
  `kubelet_extra_args` maps, which is the clean patch path.

Other verified grounding: substrate is **explicitly alpha** ("not ready for
production use ... APIs are almost guaranteed to change" -- upstream README);
supports "latest stable and previous minor" k8s (cluster runs 1.35.0 -- in
range); kagent chart latest is **0.9.12** (substrate values need >= 0.9.9);
the `AgentHarness` channel enum is `[telegram slack]` -- **Discord is not
wired by the harness** (it remains possible later via hermes' own gateway
config inside the sandbox, or a future kagent channel type).

## Decision

1. **Platform layout**: `apps/substrate` (CRDs + control plane, namespace
   `ate-system`, chart 0.0.21, bundled postgres 1Gi + rustfs 10Gi) and
   `apps/kagent` (controller + UI + substrate integration + one `WorkerPool`
   `kagent-default` of 2 replicas -- upstream docs: a long-lived AgentHarness
   pins its worker slot, so replicas = 1 + active harnesses -- with
   `ateomImage` pinned to the build matching the substrate chart
   (`ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.21`), namespace
   **`kagent-system`**, chart 0.9.12).
   The namespace is deliberately *not* `kagent` -- that namespace is owned by
   the `kagent-tools` app (WEP-0002), and one namespace managed by two ArgoCD
   apps makes either app's prune a hazard for the other. `ate-system` must
   keep its name (kagent's substrate integration defaults to
   `dns:///api.ate-system.svc:443`).
2. **The agent**: `apps/hermes` declares an `AgentHarness`
   (`backend: hermes`, `modelConfigRef: synthetic`, `workerPoolRef:
   kagent-default`) with one `telegram` channel whose `botToken` and
   `allowedUserIDsFrom` come from the 1Password-synced
   `hermes-telegram-bot` Secret. Fail-closed: the item ships with
   placeholders (hermes.tf, same pattern as synthetic.tf) and the bot is
   unusable until the real token + the operator's numeric Telegram user ID
   are pasted. **Telegram only** for now (see the enum limitation above).
3. **Model access bypasses the AI gateway**: the harness's `ModelConfig`
   (`apps/kagent/modelconfig-synthetic.yaml`) points `openAI.baseUrl` straight
   at `https://api.synthetic.new/v1` with the existing Synthetic API key
   (1Password item `synthetic`, shared with `ai-gateway-llm`), not at
   `ai.internal.willpxxr.com`. The gateway route is Auth0-gated (`llm:use`
   JWT -- apps/ai-gateway-llm/security-policy.yaml); neither hermes nor
   kagent's Go ADK client can perform that flow, and the workarounds (an M2M
   token-minting sidecar, or a new ungated gateway route) are each more
   moving parts than the problem warrants for one consumer. Accepted cost:
   hermes' LLM calls lose the gateway's audit trail (Better Stack still gets
   pod logs); revisit if more agents ride the same key.
4. **Cluster storage**: `apps/hcloud-csi` (chart `hcloud/hcloud-csi` 2.22.1,
   namespace `hcloud-csi`) provides the cluster's first StorageClass
   (`hcloud-volumes`, cluster default). Its token is the workspace
   `var.hetzner_token` written into the kubernetes 1Password vault
   (hetzner.tf `onepassword_item.hcloud_csi`) and synced via ExternalSecret --
   the provider can't mint scoped tokens. Hetzner Cloud Volumes have a 10 GB
   minimum, so substrate's 1Gi postgres request still provisions a 10 GB
   volume (~EUR 0.50/mo each); rustfs is sized 10Gi for hermes sandbox
   golden snapshots + incremental checkpoints.
5. **Control-plane alpha gates** (hetzner.tf): `kube_api_extra_args`
   (`--feature-gates=ClusterTrustBundle,ClusterTrustBundleProjection,PodCertificateRequest`
   + `--runtime-config=certificates.k8s.io/v1beta1=true`) and
   `kubelet_extra_args` (same feature gates, for ClusterTrustBundle
   projections into worker pods). **Terraform alone cannot deliver these to
   the live nodes**: the hcloud-talos module wires the machine config as
   server `user_data` at provision time only, with `user_data` under
   `lifecycle.ignore_changes` (a config change would otherwise force node
   recreation), and it has no `talos_machine_configuration_apply` resource.
   So the gates reach the live cluster via a one-time documented talosctl
   runbook (`apply-config --config-patch` per node; the kube-apiserver
   restarts itself on the config change) while hetzner.tf keeps the repo as
   the source of truth for any future re-provision. With a single
   control-plane node the apiserver restart is a brief, accepted outage.
6. **kagent minimized**: all built-in demo agents disabled, bundled
   `kagent-tools` disabled (already deployed standalone behind the MCP
   gateway, WEP-0002), and the bundled `grafana-mcp`/`querydoc` MCP extras
   disabled. The bundled PostgreSQL **stays on**: the chart refuses to render
   without a database connection ("No database connection configured"), it is
   chart-flagged dev/eval (hardcoded in-namespace credentials -- consistent
   with substrate's alpha status), and its 1Gi PVC lands on `hcloud-volumes`.
7. **Network posture** follows the repo convention (default-deny + DNS +
   kube-apiserver + described world:443 rules per dependency family);
   substrate's `ate-system` additionally allows ingress from `kagent-system`
   (ateapi gRPC 443 / atenet router 80), mirrored by egress rules on
   `kagent-system`. These are scoped namespace-wide rather than per-pod-label
   for now (component labels unverified pre-deploy) -- tighten once flow
   labels are observable.

## Plan

Phased so each push to `main` is independently survivable; ArgoCD's
sync-retry makes cross-app ordering self-healing, the phases exist to bound
blast radius:

0. **Terraform + CSI + gates** (this change): alpha gates, `onepassword_item`s,
   `apps/hcloud-csi`. Highest-risk step (kube-apiserver restart on the single
   CP) ships alone. After the apply, run the talosctl runbook (see Decision 5)
   to land the gates on the live nodes, then verify
   `certificates.k8s.io/v1beta1` appears in `kubectl api-versions`.
1. **Substrate**: `apps/substrate` converges (CRDs -> control plane; PVCs bind
   to `hcloud-volumes`). Verify postgres/rustfs Healthy, ateapi serving.
2. **kagent**: `apps/kagent` converges; controller reaches ateapi; WorkerPool
   `kagent-default` Ready; ModelConfig `synthetic` accepted.
3. **Agent + manual steps**: `apps/hermes` syncs; then by hand: create the
   bot via @BotFather, paste token + numeric user ID into the 1Password item
   `hermes-telegram-bot` (force-sync the ExternalSecret), confirm the harness
   reports `Accepted`/`Ready`, message the bot.

## Risks / mitigations

- **Substrate is alpha** (upstream's own words). Mitigation: charts pinned
  (0.0.21); one harness; rollback is deleting the app dirs (ArgoCD prune).
  Expect API churn on upgrades; treat version bumps as deliberate events.
- **Alpha feature gates** must stay enabled until substrate drops the
  pod-certificate dependency (upstream ships `podcertcontroller` as a
  polyfill "until it ships in upstream Kubernetes with different names" --
  a future k8s upgrade may rename/re-gate these; re-verify at each Talos/k8s
  bump). Note the requirement is version-coupled: substrate 0.0.6-era charts
  ran on vanilla clusters ("no feature gates required" -- upstream install
  guide); the pod-certificate path arrived later, which is also the reason
  substrate chart and kagent versions pin **together** (0.0.21 + 0.9.12 +
  ateom-gvisor v0.0.21).
- **Sizing on 3x CX23 (2 vCPU / 4 GB)**: substrate control plane +
  postgres/rustfs + kagent controller/UI + one hermes worker. Defaults were
  trimmed in values (postgres requests 100m/256Mi); if the worker pool
  OOMs, scale replicas or node types via the module -- not by shrinking
  hermes' sandbox.
- **CEL admission policies** (deny privileged containers, hostPath) apply to
  substrate's generated worker pods too; if ateom's pods need elevated
  privileges they will be rejected at admission -- that would surface as
  WorkerPool reconcile errors and needs an explicit exemption decision, not a
  silent policy carve-out.
- **rustfs capacity**: golden snapshot of the hermes sandbox (~1 GB image,
  zstd-compressed) plus incrementals; 10Gi with volume expansion available
  (hcloud CSI supports resize) if the pool of harnesses grows.
- **ArgoCD ignoreDifferences**: kagent/substrate controllers may default
  fields into harness/worker CRs at reconcile time; if syncs start flapping,
  add the kinds to `apps/argocd/values.yaml`
  (`resource.customizations.ignoreDifferences.*`) per the existing pattern.

## Rollback

Per phase, in reverse order: delete the app dir (ArgoCD prunes the app and
its resources; hermes state lives in rustfs snapshots -- export before
teardown if it matters). CSI removal only after all PVCs are gone. Terraform
gate removal is another (safe but brief) apiserver restart. The 1Password
items are inert leftovers if the stack is removed.

## Alternatives considered

- **Plain StatefulSet + PVC running `nousresearch/hermes-agent gateway run`**
  -- the initial research recommendation (fewer moving parts, native Discord,
  ~EUR 0.50 volume). Passed over by explicit user choice for the kagent
  platform value (declarative harness, UI chat surface, HITL approvals,
  snapshot/restore for future agents). Revisit if substrate's alpha churn
  outpaces its value.
- **kagent without Substrate** (declarative `Agent` CRs) -- hermes' messaging
  gateway isn't a declarative agent; messaging integrations for those go
  through separate bridge bots. Not simpler.
- **External GCS snapshots** -- unnecessary once the bundled rustfs was found
  (and would have added a GCP dependency to a Hetzner homelab).
- **Auth0 M2M sidecar / ungated gateway route for LLM access** -- both
  rejected for now (see Decision 3).
