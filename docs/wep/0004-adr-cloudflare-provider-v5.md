# ADR-0004: Cloudflare Terraform provider v5

**Date:** 2026-08-31 · **Status:** Accepted

## Context

The Cloudflare automation token is account-owned, and provider v4's token
management (`cloudflare_api_token`, the permission-groups data source) only
speaks the `/user/tokens/...` API -- an account-owned token can never call
it (error 9109), so Terraform could not mint the downscoped DNS token
WEP-0003 needs. v4 is also maintenance-only and the source of multiple
rough edges (e.g. the ConfigMap/behavior mismatch analog in
cilium/cilium#47417's class of problems).

## Decision

Bump `cloudflare/cloudflare` to `~> 5.0` (v5.24.0) and mint tokens via the
account-token surface (`cloudflare_account_token` +
`cloudflare_account_api_token_permission_groups` data source), which
natively supports account-owned credentials. Prerequisite (one-time,
granted in the Cloudflare dashboard): the automation token holds
Account/API-Tokens Read + Write.

## Migration notes

- `cloudflare_record` → `cloudflare_dns_record` with a type-level `moved`
  block (all instances carried in place; zero DNS churn -- verified in
  plan).
- v5 requires explicit `ttl` on DNS records (set to `1` / automatic,
  matching the v4 default) and a `filter` block on the zone data source.
- Ruleset `rules` and list `items` are list attributes now; dynamic blocks
  no longer validate.
- The `cloudflare_account_api_token_permission_groups` **data source
  returns a null `permission_groups` list regardless of input** (verified
  v5.24.0, even though the underlying endpoint works). The zone-scoped
  "DNS Write" permission group id is therefore pinned as a literal in
  `internaldns.tf` (stable, account-independent identifier).
- The `hcloud-talos` module float (`~> 3.1`) upgraded to 3.4.15 alongside;
  its plan diff was reviewed (cilium manifest template updates + the long
  pending removal of the WEP-0001 `flux_operator_bootstrap` state).
