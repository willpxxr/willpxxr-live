# Copilot Instructions

## Repository Overview

This repository contains the infrastructure-as-code for [willpxxr.com](https://willpxxr.com). It manages cloud infrastructure using Terraform and Kubernetes cluster configuration using FluxCD (GitOps).

## Tech Stack

- **Terraform** (`~> 1.9`) — primary IaC tool; state is stored remotely in [Terraform Cloud](https://app.terraform.io) under the `willpxxr` organization, workspace `willpxxr-live`
- **Cloudflare provider** (`~> 4.0`) — manages DNS records, redirect ruleset, WAF custom rules, and IP lists for the `willpxxr.com` zone
- **OCI provider** (`~> 7.0`) — manages Oracle Cloud Infrastructure resources: VCN, subnets, security lists, OKE Kubernetes cluster and node pool in `uk-london-1`
- **FluxCD** — GitOps manifests live under `gitops/clusters/uk/prod/cluster/` and are reconciled by the cluster; changes here are picked up automatically by Flux
- **pre-commit** — hooks enforced via `.pre-commit-config.yaml` (gitleaks for secret scanning, end-of-file-fixer, trailing-whitespace)

## Repository Structure

```
.
├── backend.tf          # Terraform Cloud remote backend config
├── providers.tf        # Provider versions and configuration
├── variables.tf        # Input variables (all sensitive)
├── locals.tf           # DNS records, redirects, WAF rules, IP lists
├── main.tf             # Cloudflare resources (DNS, redirects, WAF, lists)
├── oci.tf              # OCI resources (VCN, subnets, OKE cluster and node pool)
├── moves.tf            # Terraform moved blocks for resource renames
├── data.tf             # Data sources (Cloudflare zone and account)
├── files/
│   └── node-pool-init.sh   # OKE node initialisation script
└── gitops/
    └── clusters/uk/prod/cluster/flux-system/
        # FluxCD Kustomizations, HelmReleases, and component manifests
```

## Development Workflow

- **Terraform**: Changes to `.tf` files are applied via Terraform Cloud. No local `terraform apply` is expected; open a PR and Terraform Cloud will plan automatically.
- **GitOps (FluxCD)**: Changes to `gitops/` manifests are reconciled by the cluster automatically on merge to the default branch. No manual `kubectl apply` is needed.
- **Secrets**: All sensitive values (API tokens, private keys) are stored as Terraform Cloud workspace variables and referenced via `var.*`. Never hard-code secrets.

## Conventions

- DNS record definitions live in `locals.tf` under `local.records`; add new records there rather than directly in `main.tf`
- Redirect rules live in `locals.tf` under `local.redirects`
- WAF rules live in `locals.tf` under `local.waf`; the VPN allow-list is `local.lists.vpn`
- Use `moved` blocks in `moves.tf` when renaming or moving Terraform resources to avoid destructive changes
- The Kubernetes version is tracked in `locals` in `oci.tf` (`kubernetes_version` for the control plane, `kubernetes_node_version` for the node pool)
- Follow existing HCL formatting conventions; run `terraform fmt` before committing

## Sensitive Information

- `var.cloudflare_api_token` — Cloudflare API token
- `var.oci_rsa_private_key_base64enc` — OCI RSA private key (base64-encoded)

These must never appear in plain text in any file.
