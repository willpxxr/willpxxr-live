# AGENTS.md

> `CLAUDE.md` is a symlink to this file — one source of truth; any tool that
> auto-loads either name gets the same content.

Infrastructure-as-code for willpxxr.com: cloud infrastructure via Terraform (remote
state in Terraform Cloud, org `willpxxr`, workspace `willpxxr-live`), Kubernetes
cluster configuration via ArgoCD (GitOps).

## Agent rules (binding)

What the rest of this file describes is *how things work*; these are *what you
must do*. They apply to any agent (human or LLM) working in this repo.

1. **main is live.** Every push to `main` triggers a real Terraform apply
   (TFC) and a real cluster reconcile. There is no PR/plan gate. Run the
   `verify-infra-change` skill before every push — before, not after.
2. **Git ships, hands don't.** No manual `kubectl apply`, `helm upgrade`, or
   `terraform apply` against the cluster/TFC. Changes land via commits to
   `main` only; the documented one-time bootstraps (ArgoCD install, Terraform
   bootstrap objects) are the only exceptions.
3. **Scope**: work in `de/hetzner` unless explicitly told otherwise. `uk/prod`
   is legacy being wound down — treat as read-only.
4. **Secrets**: never hard-code, log, or echo them. Terraform inputs come from
   TFC workspace variables; cluster secrets only via the 1Password
   `ExternalSecret` pattern (see "Sensitive information" and the app
   conventions below).
5. **Decisions get recorded.** A change needing a migration plan or spanning
   multiple applies is an RFC-subtype WEP; a single non-obvious decision is an
   ADR-subtype WEP — write it in `docs/wep/` alongside the change (see
   `docs/wep/README.md` for the split).
6. **Follow the conventions below** (network-policy posture, ExternalSecret
   key layout, `moved` blocks, `terraform fmt`, Auth0 scope naming). New apps
   get scaffolded via the `new-gitops-app` skill, not improvised.
7. **Verify against reality.** CRD field names, defaults, and chart versions
   are confirmed against the live cluster's schemas or the pinned upstream
   source — never assumed from memory or from docs for a different version.
8. **Commit hygiene**: commit only what you were asked to ship (no unrelated
   working-tree changes), concise imperative message matching `git log`
   style, no amending or force-pushing published history.
9. **Keep this file current** — stale docs are bugs (see the section below).

## Clusters

- **`de/hetzner`** (`gitops/clusters/de/hetzner/cluster/`) — **the active cluster**;
  essentially all current work happens here. Talos Linux on Hetzner Cloud (`nbg1`),
  provisioned via the `hcloud-talos` Terraform module (`hetzner.tf`). Cilium CNI
  (kube-proxy replacement, native routing, Hubble) — with
  `socketLB.hostNamespaceOnly: true` in `cilium-values.yaml`, which is load-bearing:
  Cilium's socket-LB force-enables with kube-proxy replacement
  (cilium/cilium#47417), and with it active in pod namespaces, pod→ClusterIP
  traffic bypasses the netfilter DNAT hooks the Tailscale operator's proxies
  depend on — silently blackholing tailnet traffic to LoadBalancer Services.
  Envoy Gateway + Envoy AI Gateway for ingress/routing (all host routing + TLS
  termination; wildcard `*.internal.willpxxr.com` via cert-manager DNS-01), cert-manager,
  external-dns (`apps/external-dns/`, syncs `*.internal.willpxxr.com` records to
  Cloudflare from Gateway HTTPRoutes), external-secrets (1Password backend), the
  Tailscale operator. Tailnet exposure is L3-only: one `loadBalancerClass:
  tailscale` LoadBalancer Service (the Envoy data plane); the per-hostname
  Tailscale L7 Ingresses were removed (WEP-0003) — their hostname machinery is
  what caused the 2026-07/08 `svc:gateway` outage, so prefer not to bring them back.

## Tech stack

- **Terraform** `>= 1.11` (see `providers.tf`'s `required_version`) — remote backend
  (`backend.tf`), no local `terraform apply` expected.
- **Providers**: `cloudflare` (**v5** — see `docs/wep/0004-adr-cloudflare-provider-v5.md`;
  token minting for downscoped tokens uses the account-token surface, which
  needs the automation token to hold Account/API-Tokens Read+Write),
  `hcloud`/`talos` (the active cluster), `tailscale`, `onepassword`, `auth0`,
  `logtail` (Better Stack), `supabase` (mcp-token-vault project, WEP-0006 --
  static Management-API PAT; the API has no OIDC surface for the TFC
  workload-identity path Tailscale uses). Plus `kubernetes`/`helm`/`kubectl`/`tls` for the small
  set of bootstrap-only k8s objects Terraform manages directly (see below).
- **ArgoCD** (self-managed app-of-apps, see `gitops/clusters/de/hetzner/cluster/argocd/`)
  reconciles everything under `gitops/`.
- **CI** (`.github/workflows/`): OSSF Scorecard, dependency-review, Checkov
  (IaC security scanning), and a Packer build for the Talos node image.
- **pre-commit** (`.pre-commit-config.yaml`): gitleaks, end-of-file-fixer,
  trailing-whitespace.

## Repository structure

```
.
├── backend.tf, providers.tf, variables.tf   # TFC backend, provider config, all input vars
├── locals.tf, main.tf                       # Cloudflare: DNS/redirects/WAF (local.records/redirects/waf)
├── oci.tf, moves.tf                         # Legacy OCI cluster + decommission `moved` blocks
├── hetzner.tf                               # de/hetzner Talos cluster (hcloud-talos module)
├── tailscale.tf                             # Tailscale ACL/OAuth client + bootstrap k8s namespaces/Secret
├── auth0.tf                                 # Auth0 clients/scopes for every Envoy Gateway SecurityPolicy
├── betterstack.tf                           # Terraform-provisioned Better Stack API credentials/source
├── synthetic.tf                             # Synthetic LLM key: 1Password item w/ placeholder, value pasted by hand
├── argocd.tf                                # ArgoCD redis auth: random_password -> 1Password item (ESO-synced)
├── data.tf                                  # Cloudflare zone/account data sources
├── packer/talos/                            # Talos node snapshot image build
├── scripts/                                 # Helper scripts (gateway login, model sync, etc.)
├── services/                                # In-cluster services with source in this repo (mcp-token-vault, WEP-0006; CI builds/pushes the image)
├── .opencode/                               # opencode global config + ai-gateway-auth plugin (see "opencode config" below)
├── docs/wep/                                 # Willpxxr enhancement proposals (RFC + ADR subtypes) -- see docs/wep/README.md
└── gitops/clusters/de/hetzner/cluster/
    ├── argocd/        # root-app (app-of-apps) + the single apps ApplicationSet
    ├── policy/        # cluster-wide Cilium policies (its own app)
    └── apps/<name>/   # one directory per deployed component: app.yaml (+ values.yaml, manifests)
```

## Development workflow

- **Commit straight to `main`** — this is a single-developer homelab repo; PRs are
  pure overhead here and are not used. (Earlier history has some PR merges from
  before this was settled — that's not a convention to continue.) `main` isn't
  branch-protected at the GitHub level either, which is consistent with that.
- **Committing to `main` while a feature-branch checkout is active** (e.g. WEP-0005
  staging on a branch): use `git worktree add /tmp/<name> main` and commit there.
  Do NOT `git checkout main` in the branch checkout — files tracked on main but
  absent from the branch are deleted from the working tree on switch (bit us
  twice with `services/`), and stash-dances around modified files are fragile.
- **Terraform**: Terraform Cloud applies on every push to `main` (VCS-driven). No
  local `terraform apply` expected.
- **GitOps**: ArgoCD auto-syncs (selfHeal + prune) the Applications its
  ApplicationSet renders from `gitops/clusters/de/hetzner/cluster/apps/*/app.yaml`
  on push to `main`. No manual `kubectl apply`.
- A handful of k8s objects are created directly by Terraform rather than GitOps —
  only for genuine bootstrap ordering (things ArgoCD/external-secrets themselves
  depend on), e.g. the `external-secrets`/`tailscale`/`argocd` namespaces and the
  1Password ESO service-account token Secret in `tailscale.tf`. The one-time ArgoCD
  install itself was also bootstrap (helm, release `argocd`, which the `argocd`
  app then adopts). Everything else lives in `gitops/`.
- Because pushing to `main` triggers a real Terraform apply and a real ArgoCD
  sync with no PR/plan-only step in between to catch mistakes first, run the
  `verify-infra-change` skill (see below) before pushing, not after something
  breaks.

## opencode config

`.opencode/` holds the canonical opencode global config: `opencode.jsonc`
repoints the built-in `synthetic` provider at the AI gateway
(`https://ai.tailb40090.ts.net/v1`), and `plugin/ai-gateway-auth.ts` registers
the Auth0 PKCE OAuth flow on it (`opencode auth login synthetic`, silent
refresh afterwards). `~/.config/opencode/` symlinks to these files, so edit
them here, not there. The Auth0 `client_id` in the plugin is a public PKCE
native client (no secret exists), so committing it is fine.

## GitOps app conventions (de/hetzner cluster)

ArgoCD renders every app from a per-app `app.yaml` via the single
`argocd/apps-applicationset.yaml` (git files generator over
`apps/*/app.yaml` + `policy/app.yaml`). Each `apps/<name>/` directory has:

- **`app.yaml`** — the app's definition: `name`, `namespace` (omit for
  cluster-scoped apps), `dir` (cluster-relative path), and any combination of:
  `helm:` entries (`repoURL`/`chart`/`version`/`releaseName` + optional per-entry
  `values:` file; for OCI, repoURL is the full artifact path and the registry is
  registered hostname-only in `apps/argocd/values.yaml`), `kustomize:` entries
  (`repoURL`/`path`/`revision`), and `manifests:` (path globs, synced as plain
  manifests — nothing is synced implicitly). See WEP-0001 for the full schema.
- **`values.yaml`** — helm values (never synced as a manifest; consumed via the
  `$app` valueFiles reference).
- **`namespace.yaml`** + **`network-policy.yaml`** — `CiliumNetworkPolicy`,
  default-deny posture. Every namespace gets explicit `allow-same-namespace` +
  `allow-dns-egress` (+ `allow-kube-apiserver-egress` if the workload talks to
  the API server — list every controller that watches resources, not just the
  obvious ones). Egress to a specific third-party SaaS host whose IPs aren't
  enumerable uses `toEntities: [world]` restricted to port 443, one rule per
  external dependency, each with a `description` explaining *why*. `kube-system`
  is the one deliberate exception (`allow-all` — OVH-managed components whose
  requirements aren't documented). UI/exposure apps additionally need the Envoy
  data plane to reach their backend: add an egress rule to
  `apps/envoy-gateway/network-policy.yaml`'s `allow-backend-egress` (one per
  backend).
- **`externalsecret.yaml`** if it needs a secret: `ExternalSecret`
  (`secretStoreRef: ClusterSecretStore/onepassword`, **`refreshInterval: 6h`**
  — required and admission-enforced; 1Password service-account rate limits are
  tight, on-demand refresh via the `force-sync` annotation) pulling from the
  `kubernetes` 1Password vault, key convention `<item-title>/credentials/<field>`.
  When the secret's origin is another Terraform-managed provider resource rather
  than something typed in by hand, a matching `onepassword_item` resource writes
  it into that vault from the relevant `.tf` file (see `tailscale.tf`,
  `betterstack.tf`, `argocd.tf`) — prefer this over asking a human to paste a
  secret into 1Password whenever the upstream service has a usable Terraform
  provider. When it doesn't (e.g. Synthetic's LLM-gateway API key,
  `synthetic.tf`), Terraform creates the item with a placeholder value plus
  `lifecycle { ignore_changes = [section_map] }` (so later applies don't revert
  the hand-pasted key) and a human pastes the real value into the item
  afterwards; the key layout still applies.
- **Ordering**: none is encoded cross-app — ArgoCD apps whose CRDs aren't in
  place yet fail sync and converge via the retry policy. Within an app,
  Secrets/CRDs apply before CRs.
- **Controller-mutated CRs** (Envoy Gateway / AI Gateway kinds): the
  controllers write defaults into specs at reconcile time; per-kind
  `ignoreDifferences` live in `apps/argocd/values.yaml`
  (`resource.customizations.ignoreDifferences.*` — note the camelCase
  `jqPathExpressions`/`jsonPointers` keys, and null-safe jq `[]?` iterations:
  iterating null silently disables the whole normalizer). Extend them when a
  new controller-defaulted kind appears.
- **ArgoCD's own chart** lives in `apps/argocd/` (release `argocd`, adopted from
  the one-time helm bootstrap) together with its exposure (Tailscale Ingress in
  `envoy-gateway-system` + HTTPRoute + Auth0 SecurityPolicy) — the app manages
  ArgoCD itself; `dex` and the redis init Job are disabled (the init Job
  deadlocks GitOps syncs; the redis auth is ESO-managed, see `argocd.tf`).

## Observability (`otel-collector`)

An OpenTelemetry Collector agent (DaemonSet: host metrics, kubelet stats, container
log tailing) + gateway (Deployment: cluster metrics, k8s events, Prometheus
scraping, OTLP receiver) export logs/metrics/traces to Better Stack.

- Any component whose pods carry `prometheus.io/scrape: "true"` (+ `.../port`,
  `.../path`) is picked up automatically by the gateway's `prometheus` receiver —
  no otel-collector change needed to add a new metrics source.
- To add tracing from a new component, point its OTLP/gRPC exporter at
  `otel-collector-gateway.otel-collector.svc.cluster.local:4317`. Cross-namespace
  `backendRefs` (Gateway API resources, e.g. `EnvoyProxy`) need a `ReferenceGrant`
  in the `otel-collector` namespace — see
  `apps/otel-collector-gateway/referencegrant.yaml` for the pattern.
- The Better Stack source itself is Terraform-managed (`betterstack.tf`, `logtail`
  provider) — don't hand-create a source in the dashboard for this cluster.
- **Beyla (`apps/beyla/`)** runs eBPF auto-instrumentation (Grafana's OBI) cluster-wide
  (`discovery.instrument: [k8s_namespace: "*"]`) to generate traces for services that
  don't natively export OTLP (e.g. nginx in the Hubble UI frontend). Beyla's own
  built-in defaults *hard-exclude* `kube-system` (and several other platform
  namespaces) from instrumentation regardless of the `discovery.instrument` glob —
  this is `DefaultExcludeInstrument` in OBI's `pkg/obi/config.go`, layered on top of
  and independent from any `discovery.instrument`/`exclude_instrument` config we set.
  So components living in `kube-system` (Hubble UI, Cilium, CoreDNS, etc.) will never
  get server-side Beyla spans; traffic to them only shows up as the *client-side*
  span from whatever's calling in (e.g. Envoy Gateway's HTTPClient span). This is
  accepted as-is — overriding `discovery.default_exclude_instrument` to claw back
  `kube-system` was considered and deliberately not done, to keep the
  self-instrumentation/system-noise protection.

## Terraform conventions

- DNS records live in `locals.tf` under `local.records`; redirects under
  `local.redirects`; WAF rules under `local.waf` (VPN allow-list:
  `local.lists.vpn`).
- Use `moved` blocks in `moves.tf` when renaming/moving resources, to avoid
  destructive replacement.
- The Kubernetes version for the active cluster is `hetzner.tf`'s
  `module.talos.kubernetes_version`/`talos_version` (keep in sync with
  `packer/talos/talos.pkr.hcl`'s default).
- Auth0 scope naming (`auth0.tf`) is `<resource>:<tier>`, tier one of
  `get`/`admin`/`use` — see the comment at the top of `auth0.tf` for the full
  rationale before adding a new scope. Auth0 resource-server identifiers and
  all SecurityPolicy redirect URLs / audiences use
  `https://<name>.internal.willpxxr.com` (MCP carries a `/mcp` path suffix) —
  keep `auth0.tf` identifiers and the matching SecurityPolicy fields in lockstep.
- Run `terraform fmt` before committing.

## Sensitive information

All values below are Terraform Cloud workspace variables (`var.*`), sensitive,
never hard-coded:

- `var.cloudflare_api_token`
- `var.hetzner_token`
- `var.tailscale_bootstrap_oauth_client_id`
- `var.onepassword_terraform_service_account_token`
- `var.auth0_domain`, `var.auth0_mgmt_client_id`, `var.auth0_mgmt_client_secret`
- `var.betterstack_api_token`
- `var.supabase_access_token`

## Keeping this file current

This file is a live map of the repo, not a snapshot. When you learn something
material during a session — a new convention, a section here that's gone stale or
wrong, a new provider/app, a non-obvious decision and the reasoning behind it —
update the relevant section as part of that work, not as an afterthought. Edit in
place rather than appending a changelog: this file should describe what *is* true
now, not a history of edits (`git log` is the history). Architecture/workflow/
convention-level facts belong here; "why this exact line of code" belongs in a code
comment next to that code.

## Project skills

`.claude/skills/` holds skills scoped to this repo — they encode the repeatable
parts of working here so they don't have to be re-derived each session:

- **`verify-infra-change`** — run before pushing to `main`: `terraform fmt`, a
  `kubectl --dry-run=client` pass against the live cluster's CRDs for changed
  manifests, and a `helm template` render for any changed app `values.yaml`.
- **`new-gitops-app`** — scaffolds a new `apps/<name>/` directory (app.yaml +
  values.yaml + manifests) following the conventions above; the ApplicationSet
  picks the directory up automatically.

If you find yourself doing the same multi-step verification or scaffolding twice,
that's a sign it should become a skill (or an update to an existing one) rather
than tribal knowledge re-derived every time. Skills should evolve the same way this
file does — if you hit a case a skill doesn't handle, extend the skill, don't just
route around it once and move on.
