# Willpxxr Enhancement Proposals (WEPs)

Proposals for changes to this repo/infrastructure. Every WEP gets a sequential
number (never renumbered or deleted; superseded proposals get a new WEP that
says so) and one of two subtypes:

- **RFC** (`NNNN-rfc-<slug>.md`) -- expanded proposal for larger changes:
  context, decision, plan, phased execution, risks, rollback. Use when the
  change spans multiple applies/reconciles or touches the repo-wide delivery
  mechanism.
- **ADR** (`NNNN-adr-<slug>.md`) -- lightweight decision record (Michael Nygard
  format) for a single decision whose reasoning isn't obvious from the
  code/config alone, or that deliberately defers a "more correct" approach.

Rule of thumb: if the proposal needs a migration plan, it's an RFC; if its
reasoning fits on a page, it's an ADR.

| # | Type | Title | Status |
| --- | --- | --- | --- |
| [0001](0001-rfc-gitops-flux-to-argocd.md) | RFC | Migrate de/hetzner GitOps from Flux to ArgoCD ApplicationSets | Accepted |
| [0002](0002-adr-kagent-tools-shared-service-account.md) | ADR | kagent-tools MCP server: shared read-only ServiceAccount, defer per-caller OBO token exchange | Accepted |
| [0003](0003-rfc-tailnet-internal-dns.md) | RFC | Tailnet service DNS via ExternalDNS on `*.internal.willpxxr.com` | Accepted |
| [0004](0004-adr-cloudflare-provider-v5.md) | ADR | Cloudflare provider v5 | Accepted |
| [0006](0006-rfc-token-vault-mcp-credentials.md) | RFC | Token vault for ai-gateway-mcp third-party credentials (Supabase-backed) | Proposed |
