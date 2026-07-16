# CLAUDE.md

Infrastructure-as-code for willpxxr.com: cloud infrastructure via Terraform (remote
state in Terraform Cloud, org `willpxxr`, workspace `willpxxr-live`), Kubernetes
cluster configuration via FluxCD (GitOps).

## Clusters

- **`de/hetzner`** (`gitops/clusters/de/hetzner/cluster/`) — **the active cluster**;
  essentially all current work happens here. Talos Linux on Hetzner Cloud (`nbg1`),
  provisioned via the `hcloud-talos` Terraform module (`hetzner.tf`). Cilium CNI
  (kube-proxy replacement, native routing, Hubble), Envoy Gateway + Envoy AI Gateway
  for ingress/routing, cert-manager, external-secrets (1Password backend), the
  Tailscale operator (ingress is over Tailscale, not a public LoadBalancer).
- **`uk/prod`** (`gitops/clusters/uk/prod/cluster/`) — legacy OCI OKE cluster in
  `uk-london-1`, Teleport + cloudflared ingress. Treat as inactive/being wound down
  (see the OCI-decommission `moved` blocks in `moves.tf`) — don't build new things
  here unless explicitly asked to.

## Tech stack

- **Terraform** `~> 1.9` — remote backend (`backend.tf`), no local `terraform apply`
  expected.
- **Providers**: `cloudflare` (DNS/WAF/redirects for willpxxr.com), `oci` (legacy
  cluster, mostly decommission bookkeeping), `hcloud`/`talos` (the active cluster),
  `tailscale`, `onepassword`, `auth0`, `openrouter`, `logtail` (Better Stack). Plus
  `kubernetes`/`helm`/`kubectl`/`tls` for the small set of bootstrap-only k8s objects
  Terraform manages directly (see below).
- **FluxCD** (flux-operator, Kustomizations, HelmReleases) reconciles everything
  under `gitops/`.
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
├── openrouter.tf, betterstack.tf            # Per-service Terraform-provisioned API credentials
├── data.tf                                  # Cloudflare zone/account data sources
├── packer/talos/                            # Talos node snapshot image build
├── scripts/                                 # Helper scripts (gateway login, model sync, etc.)
├── docs/adr/                                # Architecture decision records -- see docs/adr/README.md
└── gitops/clusters/{de/hetzner,uk/prod}/cluster/
    ├── flux-system/    # Kustomizations, the ResourceSetInputProvider chart machinery, cluster-wide network policy
    └── apps/<name>/    # One directory per deployed component
```

## Development workflow

- **Commit straight to `main`** — this is a single-developer homelab repo; PRs are
  pure overhead here and are not used. (Earlier history has some PR merges from
  before this was settled — that's not a convention to continue.) `main` isn't
  branch-protected at the GitHub level either, which is consistent with that.
- **Terraform**: Terraform Cloud applies on every push to `main` (VCS-driven). No
  local `terraform apply` expected.
- **GitOps**: Flux reconciles `gitops/clusters/de/hetzner/cluster/` automatically on
  push to `main`. No manual `kubectl apply`.
- A handful of k8s objects are created directly by Terraform rather than GitOps —
  only for genuine bootstrap ordering (things Flux/external-secrets themselves
  depend on), e.g. the `external-secrets`/`tailscale` namespaces and the 1Password
  ESO service-account token Secret in `tailscale.tf`. Everything else lives in
  `gitops/`.
- Because pushing to `main` triggers a real Terraform apply and a real Flux
  reconcile with no PR/plan-only step in between to catch mistakes first, run the
  `verify-infra-change` skill (see below) before pushing, not after something
  breaks.

## GitOps app conventions (de/hetzner cluster)

Each `apps/<name>/` directory typically has:

- **`namespace.yaml`**.
- **`network-policy.yaml`** — `CiliumNetworkPolicy`, default-deny posture. Every
  namespace gets explicit `allow-same-namespace` + `allow-dns-egress` (+
  `allow-kube-apiserver-egress` if the workload talks to the API server) rules.
  Egress to a specific third-party SaaS host whose IPs aren't enumerable uses
  `toEntities: [world]` restricted to port 443, one rule per external dependency,
  each with a `description` explaining *why*. `kube-system` is the one deliberate
  exception (`allow-all` — OVH-managed components whose requirements aren't
  documented).
- Either a plain **`HelmRelease`** (`envoy-gateway`, `envoy-ai-gateway` — used when
  a pinned chart version or install-time flags like `crds: CreateReplace` matter)
  **or** this repo's own **`ResourceSetInputProvider` pattern** (most other charts):
  a `config.yaml` (`ResourceSetInputProvider`, labeled
  `fluxcd.controlplane.io/resourceset: charts`) supplies `name`/`namespace`/
  `repoURL`/`chart`/`valuesConfigMap`, and `flux-system/charts.yaml`'s `ResourceSet`
  templates out the actual `HelmRepository` + `HelmRelease`. This path has no
  version pin — it tracks the chart's latest. Values live in a `values.yaml` bundled
  into a ConfigMap via `configMapGenerator` (`disableNameSuffixHash: true`), named
  `<app>-values`.
- A `flux-system/kustomization-<name>.yaml` registered in
  `flux-system/kustomization.yaml`'s `resources` list, with a `healthChecks` entry
  for the HelmRelease (when there is one) and `dependsOn` only where there's a real
  ordering requirement (e.g. anything creating an `ExternalSecret` depends on
  `external-secrets-secretstore`).
- **Secrets**: `ExternalSecret` (`secretStoreRef: ClusterSecretStore/onepassword`)
  pulling from the `kubernetes` 1Password vault, key convention
  `<item-title>/credentials/<field>`. When the secret's origin is another
  Terraform-managed provider resource rather than something typed in by hand, a
  matching `onepassword_item` resource writes it into that vault from the relevant
  `.tf` file (see `openrouter.tf`, `tailscale.tf`, `betterstack.tf`) — prefer this
  over asking a human to paste a secret into 1Password whenever the upstream
  service has a usable Terraform provider.

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
- The Kubernetes version for the legacy OCI cluster is tracked in `oci.tf`'s
  `locals` (`kubernetes_version`, `kubernetes_node_version`); for the active
  cluster it's `hetzner.tf`'s `module.talos.kubernetes_version`/`talos_version`
  (keep in sync with `packer/talos/talos.pkr.hcl`'s default).
- Auth0 scope naming (`auth0.tf`) is `<resource>:<tier>`, tier one of
  `get`/`admin`/`use` — see the comment at the top of `auth0.tf` for the full
  rationale before adding a new scope.
- Run `terraform fmt` before committing.

## Sensitive information

All values below are Terraform Cloud workspace variables (`var.*`), sensitive,
never hard-coded:

- `var.cloudflare_api_token`
- `var.hetzner_token`
- `var.oci_rsa_private_key_base64enc` (legacy cluster cleanup only)
- `var.tailscale_bootstrap_oauth_client_id`
- `var.onepassword_terraform_service_account_token`
- `var.auth0_domain`, `var.auth0_mgmt_client_id`, `var.auth0_mgmt_client_secret`
- `var.openrouter_api_key`
- `var.betterstack_api_token`

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
- **`new-gitops-app`** — scaffolds a new `apps/<name>/` directory plus its
  `flux-system/kustomization-<name>.yaml` and registration, following the
  conventions above.

If you find yourself doing the same multi-step verification or scaffolding twice,
that's a sign it should become a skill (or an update to an existing one) rather
than tribal knowledge re-derived every time. Skills should evolve the same way this
file does — if you hit a case a skill doesn't handle, extend the skill, don't just
route around it once and move on.
