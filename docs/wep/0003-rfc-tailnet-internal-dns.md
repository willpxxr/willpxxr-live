# WEP-0003: Tailnet service DNS via ExternalDNS on `*.internal.willpxxr.com`

**Type:** RFC · **Status:** Accepted · **Date:** 2026-08-31

## Context

Tailnet-facing services are currently exposed twice: each service has a
Tailscale L7 `Ingress` (per-hostname MagicDNS name + per-hostname Let's
Encrypt certificate, terminated on the `ingress` ProxyGroup), *and* an
HTTPRoute-family resource in Envoy Gateway carrying the same hostname on the
plaintext listener. This duplicates TLS and hostname management, provisions
one `svc:*` VIP service and certificate per Ingress through the operator's
hostname machinery, and is rate-limit-bound (50 LE certs/week/tailnet) --
and it is where the stale `traefik/traefik-traefik` hostname duplicate that
blackholed `svc:gateway` for two months came from (see the 2026-08-31
incident: Tailscale `Service` exposure additionally requires Cilium
`socketLB.hostNamespaceOnly`, fixed in `fd3ea3c`).

The Envoy data plane is already reachable over the tailnet at L3 (the
`loadBalancerClass: tailscale` LoadBalancer Service, VIP
`100.82.41.212` / `gateway.tailb40090.ts.net`).

## Decision

1. Consolidate TLS termination at Envoy Gateway with a single Let's Encrypt
   **wildcard certificate** for `*.internal.willpxxr.com`, issued by
   cert-manager via Cloudflare DNS-01 against the existing `willpxxr.com`
   zone.
2. Run **ExternalDNS** (Cloudflare provider, `gateway-httproute` source,
   `internal.willpxxr.com` domain filter, upsert-only policy) to create
   per-host records pointing at the Gateway's status address (the tailnet
   VIP). No wildcard catch-all record -- unannotated hostnames simply don't
   resolve. Records are DNS-only (grey cloud): Cloudflare cannot proxy a
   CGNAT IP, and the IP is only routable from inside the tailnet, so public
   resolvability leaks no reachability.
3. HTTPRoute-family resources get the new hostnames and attach to the
   Gateway's TLS listener (dual-hostname + dual-parentRef during the
   migration so the old Tailscale-Ingress path and the new direct path work
   simultaneously).
4. Delete all Tailscale L7 Ingresses once the new path is verified; the
   operator reclaims their `svc:*` services and certificates. The L3
   LoadBalancer Service stays (it is now the only tailnet exposure).
5. A Cloudflare API token scoped to DNS-edit on `willpxxr.com` only is
   created by Terraform (`cloudflare_api_token`) and written to the
   1Password `kubernetes` vault (`internal-dns-cloudflare/credentials/token`);
   both ExternalDNS and the cert-manager issuer consume it via ExternalSecret
   per repo convention.

`AIGatewayRoute` supports `hostnames` (its generated HTTPRoutes inherit
them, so ExternalDNS sees the new names). `MCPRoute` does not support
`hostnames` (CRD-verified), so `mcp.internal.willpxxr.com` is advertised via
a hostname-only HTTPRoute shim (`dns-hostname.yaml`) that ExternalDNS reads
but that matches no traffic (the generated MCP HTTPRoutes match all hosts on
`/mcp` already).

## Security notes

- argocd/hubble previously sat behind `tag:admin-services` (admin-only ACL).
  Behind the shared `tag:services` VIP they are reachable by any tailnet
  device at the network layer; Auth0 SecurityPolicies at Envoy remain the
  authn/authz boundary (argocd, hubble-ui and the AI routes all carry one).
- The LE account email for the new issuer is `acme@willpxxr.com`.

## Phased execution

- **Phase A+B (one apply):** token + 1Password item (Terraform);
  ExternalDNS app; wildcard cert + Cloudflare issuer; Gateway 443 listener
  hostname `*.internal.willpxxr.com`; HTTPRoutes gain the new hostname and
  attach to the TLS listener alongside the old one.
- **Phase C (second apply, after verification):** remove old hostnames from
  routes; delete the five Tailscale Ingresses and their `app.yaml` manifest
  entries; AGENTS.md updates.

## Risks / rollback

- Rollback is `git revert` per phase: Phase C removals restore the old
  hostnames/Ingresses on the next sync; the L3 path and old L7 path are
  independent (old path works throughout Phase B).
- ExternalDNS with `upsert-only` cannot delete records it didn't create;
  the domain filter keeps it away from every other record in the zone.
- The Cloudflare token grants DNS-edit on `willpxxr.com` only.
