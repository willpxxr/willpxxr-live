# ADR-0008: Token-vault DB auth — federated identity, least privilege, PG18 revisit

**Date:** 2026-09-03 · **Status:** Accepted (design; implementation tracked separately)

## Context

The mcp-token-vault (WEP-0006) stores third-party OAuth tokens envelope-encrypted
in Supabase Postgres. Its DB access today is a long-lived static role password
(`token_vault`) with schema bootstrap at every pod start, and the GitOps image
contract redeploys the vault on *every* push to `main` (`:sha-<rev>` pinning).

The 2026-09-03 incident chain made the failure modes concrete: three
unrelated-in-nature pushes rolled the vault three times → bootstrap/connection
storms tripped Supabase's abuse limiter (worker IPv6 banned) → and, on top of an
active Supabase platform degradation ("401 errors due to JWT rejections",
API Gateway degraded), the pooler returned `(EAUTHQUERY) connection to database
not available` — leaving every MCP credential unfetchable cluster-wide with no
signal other than things breaking.

The driving threat model is **defence in depth against a faulty vault** (bugs,
bad deploys — not a compromised one: a compromised vault legitimately holds the
KEK and no DB-side control contains that). Desired end state: the client's OAuth
identity terminates as close to the DB as possible, the vault's privilege is
capped, no long-lived DB keys exist, and nothing bootstraps at pod start.

## Decision

1. **Read/visibility path** (UI, agents listing credentials):
   self-hosted **PostgREST** (small in-cluster Deployment, pointed at the
   Supabase pooler, our pool sizing) validating **Auth0 JWTs directly via
   JWKS**, with RLS policies keyed on the `sub` claim. Hosted Supabase REST is
   the fallback if self-hosting PostgREST proves unnecessary. Verify the exact
   JWKS config key against the pinned PostgREST version before implementing.
2. **Use/injection path** (hot path): the vault keeps raw sqlx with an
   **exchanged, short-lived service credential** — a supavisor JWT minted from
   the project secret (`role: token_vault_app`, minutes TTL) instead of a static
   password. Least-privilege DML on its own tables only.
3. **Role split**: `token_vault_app` (DML only) vs `token_vault_migrate` (DDL),
   migrations running exclusively in an explicit gated Job — never at pod
   startup. Role/bootstrap-on-startup is removed.
4. **Rules**: no DB transaction may span an upstream provider call; connection
   budgets are documented against the tier's `max_connections`.
5. Envelope encryption is unchanged: REST readers see opaque ciphertext;
   *use* remains vault-only. The vault can no longer *expose* credentials
   (reads bypass it) and cannot DDL — its blast radius shrinks to the rows it
   legitimately serves.

Note the recorded trust boundary: RLS is anchored to whoever validates the
claims. On the PostgREST path the edge verifies Auth0 signatures
cryptographically; on raw-SQL paths RLS trusts the vault's claim-forwarding and
is therefore advisory against the vault itself.

## Explicitly deferred — revisit at PostgreSQL 18

PostgreSQL 18 ships native OAuth 2.0 server auth (OAUTHBEARER SASL): `pg_hba`
can validate a bearer token against an issuer — i.e. **Postgres directly
accepting the forwarded Auth0 token on the wire**, eliminating the PostgREST
hop and the vault-minted service credential entirely. This is the end-state
this ADR deliberately does not adopt yet.

**Revisit triggers** (any one reopens this decision):

- Supabase offers PG18 with managed OAuth/`pg_hba` auth hooks.
- Rust driver support for OAUTHBEARER (sqlx / tokio-postgres).
- Auth0 confirmed compatible as the issuer in that flow.

Until a trigger fires, the PostgREST shape above stands.

## Consequences

- Phased migration: RLS policies + role split + PostgREST Deployment first;
  vault read-path conversion second; service-credential exchange third. Each
  phase is independently shippable.
- Supabase platform outages still take the vault down (accepted; mitigated by a
  Better Stack heartbeat on the vault admin port — separate follow-up).
- The image contract ("image IS the rollout driver", WEP-0006) that amplifies
  every push into a stateful-service redeploy is unchanged by this ADR and
  needs its own decision — see the 2026-09-03 incident notes.
