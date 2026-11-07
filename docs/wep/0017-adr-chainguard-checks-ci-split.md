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
  `substrate-images.yaml` (dispatch-only, GHCR, buildx), `talos-image.yml`
  (HCLOUD_TOKEN secret plus monthly cron), `scorecards.yml` (weekly cron and
  GitHub code-scanning SARIF upload).

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
- Revisit when Checks leaves beta: the `trust.github_token` ring is already
  required in the schema, so GitHub tokens are coming -- mcp-token-vault and
  substrate-images become migration candidates then (the vault build also
  needs persistent Docker layer caching to not regress against `type=gha`).
  talos-image additionally needs cron support and an arbitrary-secrets
  story for HCLOUD_TOKEN.
