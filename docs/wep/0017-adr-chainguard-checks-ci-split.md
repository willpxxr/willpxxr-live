# ADR-0017: Push-time CI via Chainguard Checks, GitHub Actions for the rest

**Date:** 2026-11-07 · **Status:** Accepted

## Context

GitHub-hosted runners are this repo's CI bottleneck: every push to main pays
runner queue and provision time across several workflows, with container- or
node-based action overhead on top. Chainguard Checks runs CI in fresh,
hermetic VMs and reports results as GitHub checks through the Chainguard App
(VM boots usually under a minute), but during its beta it has hard limits:
no `on: schedule` (cron), no dispatch equivalent that works without PRs, no
`secrets` context, and no GitHub token -- so no GHCR pushes, no SARIF
upload to code scanning, and no GitHub-API-driven scans.

## Decision

Split CI by what each system can actually do.

- **Moved to Checks** (`.chainguard/ci.yaml`): Checkov terraform
  misconfiguration scanning as a `postsubmit` check -- every commit landing
  on main gets a fresh-VM scan of `terraform/`. The report-only posture of
  the old workflow carries over (`--soft-fail`; findings render as
  annotations via checkov's `github_failed_only` output, which emits the
  `::error` lines Checks parses). checkov is pinned at 3.4.3, a deliberate
  bump over the 2.0.930 the old action ran -- fresher checks, so new
  findings may show up; they do not fail the check. A ring-2 cache pool
  (`.chainguard/ci/identities.yaml`) keeps the pip install warm.
- **Cut-over completed 2026-11-07**: `.github/workflows/checkov.yml` was
  removed once the Checks-side scan superseded it (module internals scanned,
  findings as annotations; green runs `8614a44`, `8f36b87`, `af8f3fb`).
- **Deleted**: `dependency-review.yml` -- PR-triggered only, this repo
  deliberately has no PRs, so it had never run.
- **Stays on GitHub Actions**, each blocked by a beta limit rather than
  inclination: `mcp-token-vault.yml` (per-push GHCR publish behind the
  GitOps sha-<commit> image pinning -- needs a GitHub token),
  `substrate-images.yaml` (GHCR, buildx; trigger modernized 2026-11-07 to
  fire on a committed bump to `.github/substrate-ref`, with
  `workflow_dispatch` kept as the rebuild-forcing override -- the build
  itself waits on credentials), `talos-image.yml` (HCLOUD_TOKEN secret plus
  monthly cron), `scorecards.yml` (weekly cron and GitHub code-scanning
  SARIF upload).

## Consequences

- Checkov findings no longer land in the GitHub Security tab (no token to
  upload SARIF with); they hang off the commit's `Chainguard Checks
  (postsubmit)` check as annotations instead. Scorecard's Security-tab
  upload is unaffected -- that workflow stays on GHA.
- Postsubmit cannot gate anything here: pushes go straight to main and
  Terraform Cloud applies in parallel. Checks buy fast feedback and a
  hermetic-egress posture, not enforcement; enforcement would require PRs,
  which this repo does not use.
- `identities.yaml` doubles as the trust anchor: the owner's GitHub user id
  pinned in ring `1.trusted`, the cache limited to ring 2. A future PR flow
  inherits working trust semantics from day one, and an untrusted opener
  would correctly get neither cache nor trust.
- Revisit when Checks leaves beta. Endgame decided 2026-11-07: stay on GHCR
  and wait for the GitHub token (`trust.github_token` is already required
  in the schema) -- mcp-token-vault and substrate-images become migration
  candidates then (the vault build also needs persistent Docker layer
  caching to not regress against `type=gha`). The cgr.dev alternative is
  closed on the free tier: pushing through a Chainguard workload identity
  needs an assumable identity, and Starter organizations cannot create
  identities (pull tokens only), so it would take a paid plan plus a GitOps
  registry migration. talos-image needs an arbitrary-secrets story on top:
  hcloud has no OIDC surface to federate a workload identity with, so it
  waits for a generic secrets mechanism (its monthly cron is GHA-shaped
  regardless).
