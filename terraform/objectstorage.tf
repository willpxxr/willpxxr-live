# Hetzner Object Storage (S3) for substrate snapshots, WEP-0016 Phase 1
# (Decision §2: provider-durable snapshots; rustfs stays the recorded
# fallback, not this fleet's default).
#
# Product reality, verified 2026-10-26: Object Storage has NO Cloud API --
# the hcloud provider cannot manage buckets or credentials (registry guide
# "Use Hetzner Object Storage (S3)";
# hetznercloud/terraform-provider-hcloud#1005). The official docs route is
# the MinIO provider against the S3 data-plane endpoint
# (docs.hetzner.com ST-507F6, "Creating a Bucket via MinIO Terraform
# Provider"; 3.33.1 pinned there and in providers.tf as the Hetzner-
# verified version). Buckets created this way appear in Hetzner Console.
# Keys are Console-generated; the flow:
#
#   1. Hetzner Console -> project -> Security -> S3 Credentials: generate
#      the MANAGEMENT pair, set TFC workspace vars s3_access_key +
#      s3_secret_key (write-only -- paired with the `ephemeral`
#      declarations in variables.tf, the hard requirement; provider
#      configuration is the one sanctioned context, so those values
#      never touch state).
#   2. generate the RUNTIME pair (dedicated -- Hetzner keypairs are
#      project-wide by default, bucket create/delete included, and the
#      runtime Secret lives inside the cluster; a second pair isolates
#      rotation and attribution). Set TFC workspace vars
#      substrate_s3_access_key + substrate_s3_secret_key as regular
#      Sensitive (write-only OFF -- Terraform must persist them into the
#      `substrate-s3` 1Password item below, and ephemeral values cannot
#      cross into resource attributes).
#   3. Applies create the bucket and keep the item current; the
#      install-slice ExternalSecret consumes
#      substrate-s3/credentials/access_key_id + .../secret_access_key.
#      True blast-radius reduction is bucket-policy-based (S3
#      PutBucketPolicy via minio_s3_bucket_policy -- naturally
#      TF-reachable through var.substrate_s3_access_key), not a console
#      toggle; recorded as follow-up hardening: runtime key limited to
#      object R/W on this bucket.
#
# Object locking is deliberately OFF (unlike the public WORM/gist
# examples): substrate rewrites and prunes its snapshot blobs;
# retention is the runtime's job and COMPLIANCE-mode locks would break
# restore/rotation.
#
# nbg1 = the cluster's location; node -> bucket traffic rides the free
# eu-central internal zone. Install-slice env surface (upstream-recorded):
# ATE_STORAGE_BACKEND=s3, AWS_ENDPOINT_URL=https://nbg1.your-objectstorage.com,
# AWS_S3_USE_PATH_STYLE=true, static keys from the ExternalSecret.

locals {
  substrate_s3_bucket = "willpxxr-live-substrate-snapshots"
}

resource "minio_s3_bucket" "substrate_snapshots" {
  # No count-gate: the s3_* variables are ephemeral (TFC write-only
  # pairing -- see variables.tf), and count expressions are persistent
  # context that may not read them. Missing keys therefore fail the apply
  # loudly instead of the bucket silently not existing; configure itself
  # stays offline pre-keys (s3_compat_mode skips the admin probe -- see
  # providers.tf).

  bucket         = local.substrate_s3_bucket
  acl            = "private"
  object_locking = false
}

# Runtime credentials for substrate's objectstore-plugin sidecars (atelet +
# ate-api-server): the dedicated runtime pair, carried as regular TFC
# workspace variables and written by Terraform as the writer-of-record --
# the mcp-token-vault item posture (owner decision, 2026-10-26: masked
# values do persist in state; chosen over a 1Password hand-paste). These
# vars must be regular Sensitive, NOT write-only (see header).
resource "onepassword_item" "substrate_s3" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "substrate-s3"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        access_key_id = {
          type  = "CONCEALED"
          value = var.substrate_s3_access_key
        }
        secret_access_key = {
          type  = "CONCEALED"
          value = var.substrate_s3_secret_key
        }
      }
    }
  }
}
