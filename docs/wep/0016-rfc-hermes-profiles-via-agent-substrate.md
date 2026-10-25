# WEP-0016: Hermes agent profiles via Agent Substrate

**Type:** RFC · **Status:** Accepted (2026-10-25; drafted 2026-10-24; fleet
direction revised to stay-hcloud 2026-10-25, snapshot backend to Hetzner
Object Storage 2026-10-25) · **Date:** 2026-10-24

## Context

Hermes (WEP-0014) is currently a chatbot: Discord + dashboard, one pod, and
`terminal.backend: local` — the agent's code execution shares its container with
every credential it owns (the Auth0 M2M client carrying *all* `llm:*` scopes,
the Discord token, the parked MCP tokens). It has no meaningful coding,
architecture, or review capability, and no safe way to acquire one: any GitHub
credential handed to it would sit inside the same terminal it executes
untrusted commands in. Upstream hermes has no GitHub App auth yet
(NousResearch/hermes-agent#4193; PR #69972 adds in-process installation-token
minting — exactly the credentials-in-the-sandbox pattern we want to avoid).

The goal: **profiles** — coder, architect, reviewer (security + SRE lenses),
SRE — with different capabilities, different credentials, and credentials
that are *attached* to work without ever being held by agent-executed code.

[Agent Substrate](https://github.com/agent-substrate/substrate) ("ate",
Google-backed, Apache-2.0, pre-1.0) is the runtime that provides that
property. Actors run in gVisor or Cloud-Hypervisor microVM sandboxes (plain
containers are unsupported) with **zero credentials in the sandbox**: the
actor sends an `Authorization` header with a placeholder value, and the
`atenet-egress` gateway resolves the real credential from a provider and
swaps it in *outside* the sandbox, fail-closed. A prompt-injected or
compromised actor has nothing to read, snapshot, or exfiltrate. The bundled
`k8s.io` credential provider reads Kubernetes Secrets behind a default-deny
atespace→namespace policy; custom providers implement `FetchSecret` over
mTLS with the gateway's SPIFFE identity. Per-actor SPIFFE identities and
minted actor JWTs exist for future federation. Suspend/resume snapshots make
idle actors ~free (relevant at our node sizes). Requirements: Postgres, an
S3-compatible snapshot store (rustfs), k8s latest + previous minor (1.37 /
1.36 today; the cluster runs 1.36.4).

Sandbox class constraint (unchanged by the fleet decision): hcloud VMs are
KVM guests without nested virt, so the Cloud-Hypervisor microVM class is
unavailable — **gVisor (runsc) is the sandbox class**, via the official
`siderolabs/gvisor` Image Factory extension. True bare metal would unlock
microVMs, but the credential-isolation property this RFC exists for is
delivered by egress injection, not by the sandbox class.

### Fleet decision: stay on hcloud, as-is, in place (2026-10-25)

The fleet stays de/hetzner and stays exactly as it is — no new nodes, no
type bumps, no new spend beyond volumes. This is partly preference (zero
commitment, full TF-managed lifecycle through the existing `hcloud-talos`
module + Packer pipeline, all AGENTS.md conventions intact) and partly
force: the cost-optimized line is showing "currently unavailable" across
SKUs at check time (2026-10-24), so a CX43 bump or 4th node couldn't be
ordered today regardless. Substrate squeezes onto existing compute with
the structure below, and the upsize-on-restock exit is the recorded way
out when contention or demand justifies it.

| Node | Product | Spec | Role | €/mo (ex-VAT) |
| --- | --- | --- | --- | --- |
| control-plane-1 (existing) | CX23 | 2c / 4 GB | CP (single, for now — see below); hosts no actor workloads | 5.99 |
| worker-1 (existing) | CX23 | 2c / 4 GB | hermes orchestrator, mcp-token-vault + ate control plane (gVisor image) | 5.99 |
| worker-2 (existing) | CX33 | 4c / 8 GB | Valheim + actor pool (gVisor image) | 8.99 |
| Actor workspace PVCs (if any — §2) | hcloud Volumes | — | actor workspaces only | ~1–3 |
| Substrate snapshots | Hetzner Object Storage | — | S3 blobs, provider-durable (§2) | ~5.99 |
| **Total** | | | | **~€27–31** (~€32–37 incl. VAT) |

Recorded structure of the squeeze (the zero-spend path is the plan of
record *because* the cost-optimized line is showing "currently unavailable"
across SKUs at check time (2026-10-24) — a CX43 bump or 4th node cannot
currently be ordered regardless of preference):

- **Placement**: ate control plane (api server, controller, atenet,
  credential provider, atelet) on worker-1's ~1.5–2 GB margin; actor
  scheduling on worker-2's larger margin (substrate's Postgres and
  snapshot blobs are both off-cluster — Decision §2), with worker-1 as
  overflow for at most one light actor.
- **Contention rules**: actor Pods sit at a PriorityClass below substrate
  infra and below Valheim — memory pressure evicts/suspends actors first
  (substrate suspends idle actors rather than letting the node OOM-kill
  through the stack). Known human-enforced limitation, recorded, not
  designed: no heavy coder builds during play sessions.
- **Upsize-on-restock — the recorded exit from the squeeze**: when
  cost-optimized stock returns, prefer the worker-1 CX23 → CX43 type bump
  (+€10.50/mo; keeps 3 nodes; the taint-replace carries the gVisor image
  for free) over adding a 4th CX43 node (€16.49/mo, cleanest isolation).
  CX43 over CAX31 recorded for that day: €5/mo less at the same 8c/16 GB
  shape, single-arch means `services/` CI never needs an arm64 target
  (hermes upstream is multi-arch regardless); CAX31's Altra
  fixed-clock/no-SMT determinism was judged marginal. Trigger to take the
  exit: contention costing real work (suspension evictions of active
  profiles), or a second concurrently-active profile on a Valheim-heavy
  week. CX53/CAX41 beyond that if several profiles run hot.

Deliberately retained/deferred (recorded so silence isn't mistaken for
oversight):

1. **Single-CP fragility stays, for now.** The netcup re-provision would
   have fixed etcd quorum as a side effect; staying means the documented
   single-point-of-total-failure posture of `terraform/hetzner.tf` carries
   forward until a dedicated 3-CP conversion (its own change, WEP-sized).
   Trigger to pull it forward: the first real CP outage, or Phase 3
   landing making the profiles production-ish.
2. **Storage premium is being paid** (~€0.058/GB for substrate state vs
   netcup's bundled NVMe) — accepted as the price of TF-managed lifecycle
   and zero migration risk; revisit trigger for the fleet direction below.
3. **Longhorn/Rancher-style replicated block storage is deferred** — a
   bundled-NVMe(netcup)-motivated design; `hcloud-volumes` is the
   battle-tested in-repo convention (hermes, Valheim PVCs) and substrate
   state rides it unchanged.

### Deferred fleet alternatives — math preserved, revisit triggers recorded

**netcup re-provision ("N1-lite")** — prices checked 2026-10-24, ex-VAT,
12-month terms: VPS 500 ARM (€8.26) + VPS 1000 x86 (€14.50) + VPS 1000 ARM
(€14.50) = **€37.26/mo (~€44.34 incl)**, three schedulable CP members (etcd
quorum as a side effect), 320 GB bundled NVMe (~160 GB Longhorn-RF2-usable
for €0), netcup in-generation CCP upsizes. Concessions: manual ordering (no
create API), ISO installs (siderolabs/talos#12505 rough edges), TF lifecycle
loss, 12-month floor. Term-ladder variant: order at 1-month rates
(€42.83/mo ex, ~+15%), extend to 12M at a convergence gate — flex premium
≈ €11 ex for the trial window, worst-case sunk ~€86 vs €447; 24M option
€31.69/mo ex with a two-year G12.5 generation lock.
**Re-open if**: substrate-driven storage spend (volumes + object store)
passes ~€15/mo with the
fleet bill trajectory heading past ~€60/mo, or cost-optimized stock is
still unavailable when contention makes the worker bump unavoidable
(paying regular-performance prices for it instead — at which point netcup
prices re-enter the comparison honestly).

**Self-hosted hardware** — benchmarks vs the fully-grown stay-hcloud fleet
including the eventual worker bump (~€57.4/mo incl; against today's squeezed
~€32–36 incl every breakeven stretches ~50% — micro PC ~12 mo, workstation
~33, Pi ~41); electricity €0.35/kWh (EU range €0.29–0.41); power averaged
over substrate's idle-suspended duty cycle; all-in includes a UPS; home
broadband assumed sunk:

| Config | All-in | Power | Net saving/mo | Breakeven |
| --- | --- | --- | --- | --- |
| 1× used micro PC (6c/32GB, 1 TB NVMe) + UPS | ~€400 | ~20 W ≈ €5/mo | ~€52/mo | **~8 mo** (~9 with a tunnel VPS) |
| 1× used 16c/64GB workstation (2 TB) + UPS | ~€950 | ~35 W ≈ €9/mo | ~€48/mo | ~20 mo |
| 3× Pi 5 16GB (home quorum) | ~€865 | ~25 W ≈ €6/mo | ~€40/mo* | ~21 mo* |

*The Pi row keeps a cloud x86 node (~€10.7/mo incl) for Valheim (x86/Wine)
and rides 2026's memory-shortage pricing (Pi 5 16GB: $120 → $205) —
dominated by the micro PC either way. Rejection grounds (unresolved by
baseline choice): residential-line public UDP for Valheim (CGNAT/ToS; a
tunnel VPS reintroduces a cloud dep), single-box SPOF vs any cloud fleet,
fixed capacity, ops surface. **Re-open if** the recurring bill passes
~€80/mo (2× the micro-PC's amortized cost). Genuine plus recorded: bare
metal is the only option able to run substrate's microVM sandbox class
(/dev/kvm).

## Decision

1. **Fleet**: no re-provision and no new nodes. Workers 1+2 take the gVisor
   schematic via in-place image upgrade (Phase 0's validation *is* that
   upgrade, WEP-0009 ritual); actor placement is bounded by nodeSelector +
   the PriorityClass rules in the fleet section — ate control plane on
   worker-1, rustfs + actors on worker-2.

2. **Storage**: substrate's entire state lives off-cluster. Postgres
   backend: the **existing Supabase project** (WEP-0006's project; the
   mcp-token-vault DB-auth pattern from 0008-adr-vault-db-auth-federation
   supplies the app→DB credential convention — dedicated database + role,
   secret via 1Password → ExternalSecret; upstream supports the
   external-Postgres shape via its Cloud SQL path). Snapshots: **Hetzner
   Object Storage** (S3 API, provider-durable; ~€6/mo base incl 1 TB —
   ~10–20× our blob needs) as the primary store — upstream's own posture,
   since the bundled rustfs is documented as a *non-durable dev default*
   ("move a production installation to your own bucket before it carries
   real traffic"). Config surface is upstream-documented:
   `rustfs.enabled: false` + `atelet.storageBackend: s3` (the
   `ATE_STORAGE_BACKEND` env on the objectstore-plugin sidecars of atelet
   and ate-api-server) with `AWS_ENDPOINT_URL`, `AWS_S3_USE_PATH_STYLE:
   "true"`, and static R/W keys — bucket + credentials TF-managed (hcloud
   provider's object-storage resources; verify the provider version
   surface in Phase 0), keys into 1Password → ExternalSecret, held
   control-plane-side only, never inside actors, consistent with the
   zero-credential model. This also sheds rustfs's 1Gi PVC + sidecar
   memory from the squeezed fleet, and with the registry in Supabase
   makes substrate survivable against any node or the whole single-CP
   cluster (rebuild = reinstall + re-point). Rustfs remains the recorded
   fallback if a pinned substrate version regresses the S3-client config.
   `hcloud-volumes` carries only actor workspace PVCs that Phase 0
   proves necessary. Longhorn/Rook/MinIO-distributed stay deferred with
   the netcup direction (recorded above).

3. **Hermes becomes two classes of thing**:
   - **Orchestrator** (existing `apps/hermes` Deployment, unchanged in kind):
     Discord + dashboard + memory + intake; holds trusted low-value
     credentials (its M2M, Discord); gains a scoped ServiceAccount limited to
     substrate CRDs + `kubectl-ate` dispatch. Its network policy gains
     kube-apiserver egress for exactly those verbs.
   - **Profiles as substrate ActorTemplates**, one per profile, each in its
     own atespace: `hermes-coder`, `hermes-architect`, `hermes-reviewer`,
     `hermes-sre`. Actor images run the hermes image (amd64; upstream is
     multi-arch) headless with a per-profile HERMES home (toolsets, skills,
     SOUL context) and a per-profile Auth0 M2M client. The dispatch seam
     (orchestrator → actor) is ours until hermes gains an upstream substrate
     terminal backend (Nous is a Substrate design partner; the seam is
     designed to be replaced one-to-one by that backend).

4. **GitHub Apps are the GitHub credential mechanism** — bot identity,
   per-app least privilege, ≤1h installation tokens, no PATs. Four apps,
   created once via GitHub's UI (no create-API exists; same class of
   documented one-time manual bootstrap as the ArgoCD install). PEM + app +
   installation IDs live in 1Password (`kubernetes` vault,
   `github-app-hermes-<profile>/credentials/{app_id,installation_id,private_key}`,
   hand-typed once — synthetic.tf placeholder precedent), synced via
   ExternalSecret:

   | App | Permissions | Repo access |
   | --- | --- | --- |
   | hermes-coder | contents RW, pull_requests RW | willpxxr-live |
   | hermes-architect | contents RW, pull_requests RW | willpxxr-live |
   | hermes-reviewer | contents R, pull_requests RW | willpxxr-live |
   | hermes-sre | contents R, issues RW | willpxxr-live |

   Pushes only ever land on feature branches; merges stay human. The
   orchestrator uses hermes-reviewer's token (held in the trusted class) to
   poll for open PRs.

5. **Token minting is External Secrets’ `GithubAccessToken` generator**
   (`generators.external-secrets.io/v1alpha1`, per
   https://external-secrets.io/latest/api/generator/github/) — no custom
   minter service. Per profile, a generator + ExternalSecret pair in the
   profile’s own namespace (ESO requires generator-referenced Secrets to
   be co-namespace): `appID`/`installID` as literal manifest fields — they
   are public identifiers, not secrets, same reasoning as the committed
   PKCE client_id in `.opencode`’s gateway plugin — the PEM from the
   existing 1Password → ExternalSecret Secret, `refreshInterval: 15m`
   (GitHub’s 60m token expiry is non-configurable), and the token Secret
   named for the §6 `credentialUri` for the bundled `k8s.io` credential
   provider to inject. The generator’s optional `permissions:`/
   `repositories:` fields down-scope each minted token below the app’s
   installation grants — the reviewer mints `contents: read` — a second
   least-privilege layer matching each EgressPolicy. Verify the generator
   CRD is served by the pinned chart (2.10.0) at implementation per
   AGENTS.md rule 7; the `appIDRef`/`installIDRef` secretRef variant is
   newer — literals are the version-safe default. Successor if ever
   outgrown: a custom `FetchSecret` provider with per-actor authorization
   (Rust; credprovider.proto; gateway-mTLS-pinned; Giant Swarm’s
   agent-platform as prior art) — much less likely to be needed now that
   minting lives inside ESO.

6. **Egress is the credential boundary**: per-profile EgressPolicy `https`
   rules for `api.github.com` + `github.com` with a `replaceHeaders` effect —
   actors send `Authorization: placeholder` and never see the real token:

   ```yaml
   rules:
   - https:
       hostnames: ["api.github.com", "github.com"]
       effects:
         replaceHeaders:
         - header: Authorization
           prefix: "Bearer "
           credentialUri: ate-secret://k8s.io/<ns>/github-installation-token-hermes-coder/token
   ```

   (Field names illustrative; verify against live CRDs at implementation —
   AGENTS.md rule 7.) Git transport is HTTPS-only with placeholder headers
   (`http.extraHeader`, `GH_TOKEN=placeholder`, trust-bundle CA projection);
   SSH git is not injectable and is not used by profiles.

7. **Reviewer is built hostile-input-first**: read-only app, egress allowlist
   limited to GitHub + the AI gateway, no terminal in the reviewer template
   (or a read-toolset terminal) — a malicious PR can at worst produce a
   review comment. Trigger is orchestrator cron polling for open PRs; a
   public webhook endpoint (which would make this the first public HTTP
   workload and needs its own perimeter decision) is explicitly deferred.

8. **Per-profile LLM identity**: one Auth0 M2M client per profile with
   minimal scopes (coder `llm:auto`, reviewer/architect `llm:small`, SRE
   `llm:auto`) — each in-process-refreshed by the existing WEP-0014 provider
   plugin inside the actor. Strictly better blast radius than today's single
   all-scopes client even though these credentials do live in the sandbox.
   Federating substrate actorJwt to the AI gateway's SecurityPolicy (no M2M
   clients at all) is the noted successor, deferred.

## Plan

### Phase 0 — feasibility spikes

1. **Substrate on kind**: quickstart install, `k8s.io` provider, httpbin
   header-injection smoke, sandbox demo actor, suspend/resume, version
   requirements vs 1.36; wire external S3 (`ATE_STORAGE_BACKEND=s3`,
   `AWS_ENDPOINT_URL` + path-style on the objectstore-plugin sidecar)
   against a Hetzner Object Storage test bucket and exercise
   suspend/resume through it — upstream documents the path, so this is an
   integration test, not a feasibility question (mind the `AWS_REGION`
   quirk);
   confirm how atelet expects to find runsc on nodes vs Talos's RuntimeClass
   wiring; determine an ArgoCD-adoptable install shape (rendered
   manifests); record hermes-actor RSS under a coding workload to calibrate
   the upsize-on-restock trigger. Also prove the external-Postgres config
   surface (the Cloud SQL path) against a throwaway Supabase database:
   Postgres version compatibility, session-mode vs transaction-mode
   pooling (prepared statements break under transaction pooling), and the
   project's plan tier (connection caps; free-tier inactivity pausing would
   be a non-starter — and the project now carries mcp-token-vault AND
   substrate, so its uptime/plan review covers two tenants).
2. **gVisor-on-Talos in-place validation** (no throwaway node is possible
   while cost-optimized stock is out — the spike *is* the first real
   upgrade): add `siderolabs/gvisor` to `packer/talos/schematic.yaml`,
   build the installer image + Packer snapshot, then upgrade **worker-1**
   in place with the full WEP-0009 Phase A ritual — fresh off-node etcd
   snapshot, one node only, verify machine `running` + node Ready + hermes
   back, gVisor RuntimeClass smoke pod executes under runsc, 30 min clean;
   `talosctl rollback` is the standing escape. Worker-2 takes the same
   image only after worker-1 converges — never both at once.
   Decision (2026-10-25): the gVisor roll runs at the fleet's current
   versions — Talos v1.13.9 / k8s 1.36.4. The OS/k8s bump is *not* folded
   into this window: a failed window must attribute to exactly one change
   (WEP-0009's one-at-a-time discipline), and the bump is
   prerequisite-chained regardless — per the runbook matrix, Talos 1.14
   first, then Cilium ≥ 1.21 (matrix re-verify) before k8s 1.37. That
   campaign runs later as its own effort; gVisor rides the schematic
   forward at its Talos step with no special handling — the snapshot
   rebuild doubles as its per-version extension check (catalogue cuts
   gvisor for v1.14.4, checked 2026-10-25; v1.13.12 exists on the current
   line — point releases are not free riders either). The CP node, hosting
   no actor Workers, takes gVisor as a passenger at its 1.14 in-place
   bump — no separate v1.13.9 roll.
3. **SKU stock watch** for CX43 (the upsize-on-restock exit) — nothing
   blocks while it's out; the squeeze is the standing plan.

Gate: all green → substrate lands as placed in the fleet section. A failed
worker-1 upgrade that survives rollback → hold the fleet; substrate waits
for stock with the alternatives' math recorded.

### Phase 1 — substrate install on the squeezed fleet

- Workers 1+2 already carry the gVisor schematic from Phase 0; label them
  for the substrate WorkerPool (no new node, no taint — actor placement is
  bounded by nodeSelector + the PriorityClass rules recorded in the fleet
  section).
- `apps/substrate` scaffolded via `new-gitops-app` (manifests source;
  controller-mutated CRDs get `ignoreDifferences` entries per convention);
  substrate's Postgres backend points at the existing Supabase project
  (dedicated database + role per Decision §2, connection secret via
  ExternalSecret); snapshots go to the Hetzner Object Storage bucket
  per Decision §2 (`ATE_STORAGE_BACKEND=s3`, endpoint + path-style +
  static keys via ExternalSecret into the objectstore-plugin sidecars);
  `hcloud-volumes` only for workspace PVCs Phase 0 proves necessary;
  `k8s.io` credential provider; ate-system namespace Cilium policies per
  convention, with egress for the bucket endpoint AND the SandboxConfig
  asset URL (nodes fetch sandbox binaries from an upstream public
  bucket — restricted egress needs that path or a self-hosted copy);
  **the socket-LB probe runs first** — substrate's
  router/gateway are ClusterIP-proxying components, the exact precedent
  class of the 2026-07/08 Tailscale blackholing. Worker-path probes (DNS
  via ClusterIP 10.0.8.10, cross-node) per the k8s-upgrade runbook.
- Namespace-policy grants: one namespace per atespace, one atespace per
  profile; provider RBAC scoped to those namespaces only (the bundled
  cluster-wide Secret read is a docs-flagged production hazard — we don't
  ship it unscoped).

### Phase 2 — credential chain

- GitHub Apps bootstrapped (UI, once); 1Password items; ExternalSecrets;
  ESO `GithubAccessToken` generator + ExternalSecret per profile (§5); per-profile Auth0 M2M clients in `terraform/auth0.tf`
  following the existing scope naming and alias conventions; end-to-end
  injection smoke against an echo service before any real repo access.

### Phase 3 — profiles go live, one at a time

Order: **coder** (validates terminal + git-HTTPS placeholder flow + PR
end-to-end on a real branch) → **reviewer** (poll trigger via orchestrator
cron; hostile-input posture §7) → **architect** (WEP/ADR drafting via PRs,
given the repo's conventions as its sandbox — an unusually fitting test) →
**SRE** (adds injected read-only cluster SA token — the WEP-0002 kagent-tools
precedent — plus injected Better Stack key for telemetry queries; write
capabilities explicitly out of scope for v1).

Each profile ships: ActorTemplate, atespace, EgressPolicy, GitHub App +
1Password item + token generator, per-profile M2M client, skills/persona home,
dispatch smoke, and one real exercised PR recorded in this WEP's execution
record.

## Consequences

- No migration and no new nodes: today's de/hetzner cluster hosts
  substrate; node lifecycle stays TF-managed; new spend is €6/mo of
  object storage plus €1–3/mo of workspace PVCs (registry in Supabase,
  snapshot blobs in the bucket — substrate's entire state is off-cluster;
  a cluster rebuild is reinstall + re-point). The worker-1 → CX43 bump
  (+€10.50/mo) is the recorded upsize-on-restock exit when contention or
  demand justifies it.
- The netcup re-provision and self-hosted options remain live alternatives
  with preserved math and explicit revisit triggers (~€60/mo trajectory →
  netcup; ~€80/mo → self-host); the single-CP quorum gap is the known
  fragility carried forward, deliberately, until its own change.
- substrate is pre-1.0: versions are pinned, upgrades follow its upgrade
  runbook, and breaking changes are expected inventory.
- Hermes upstream moves (GitHub App auth, substrate terminal backend) may
  obsolete pieces of §3 and §5 — seams are designed to swap cleanly.

## Risks / rollback

- **Single CP retained**: substrate's availability is bounded by the CP
  node like everything else — the pre-existing accepted posture, now
  recorded as deliberate rather than omitted. Quorum conversion is the
  follow-up WEP if this bites.
- **Contention is the standing risk** (SKU availability is moot — nothing
  is being ordered): Valheim peak (~2.8 GB) + an active ~2–2.5 GB actor +
  substrate stack on one 8 GB node is OOM territory; mitigation stack in
  order: PriorityClass eviction → substrate suspends idle actors under
  pressure → the no-builds-during-raids rule → the upsize-on-restock exit.
  Worker-1 hosts the ate control plane plus at most one light actor.
- **Substrate ↔ Cilium socket-LB**: probe-first discipline (§Phase 1);
  actors pin to worker-2 if worker-1's margin proves too thin.
- **In-place worker image upgrades are the 2026-09 incident class**: the
  gVisor schematic reaches both workers only through the WEP-0009 ritual
  captured in Phase 0 — etcd snapshot, one node at a time, `running` +
  workload verification, `talosctl rollback` standing by.
- **Injection is fail-closed by design** — misconfiguration surfaces as
  403/503 on GitHub calls, never as un-credentialed passthrough; the
  provider ConfigMap needs a provider restart to reload (ops note).
- **git-HTTPS placeholder flow** is the most fragile client-side piece
  (http.extraHeader/credential-helper quirks); validated in Phase 3 coder
  before the reviewer depends on any of it.
- **Snapshot I/O rides the object store**: resume fetches blobs across
  hcloud's internal network — the same latency class the rustfs-on-volume
  path would have had, so no regression; Phase 0's resume-latency smoke
  is the watch-item. For any future backup/lifecycle policy: cover both
  `actors/` and `tags/` prefixes — checkpoints live under `tags/`, and
  an `actors/`-scoped policy silently misses them (upstream-documented
  layout).
- **Supabase is substrate's system-of-record**: the project's uptime now
  bounds two tenants (mcp-token-vault + substrate registry; snapshot
  blobs live in the Hetzner Object Storage bucket). DB RTT adds ~tens of
  ms to actor
  create/resume/suspend — immaterial next to snapshot I/O, but connections
  stay on session-mode pooling (Phase 0 verifies prepared statements), and
  a cluster rebuild restores substrate from the surviving DB — a real DR
  improvement under the retained single-CP posture.
- Rollback: `apps/substrate` → `app.yaml.disabled` + CRD cleanup per the
  disabling convention; the workers' gVisor image is benign to keep (one
  WEP-0009 cycle reclaims it if ever wanted).

## What's not included (deliberately deferred)

- 3-CP etcd quorum conversion (pre-existing posture, trigger recorded).
- netcup re-provision and self-hosted hardware (math + triggers above).
- Public GitHub webhook ingress — first public HTTP workload; its own WEP.
- Substrate actorJwt → AI gateway SecurityPolicy federation (§8 successor).
- Per-user MCP authorization (carried over from WEP-0014).
- The hermes orchestrator's own parked MCP paste-back (`hermes mcp login`,
  WEP-0014 "Not yet working") — orthogonal; injection may cover the profile
  actors before the orchestrator's flow is ever resumed.
- SRE write/remediation capabilities; microVM sandbox class; uk/prod
  (read-only).
