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
# Keys are Console-generated; the checklist:
#
#   1. Hetzner Console -> Object Storage: generate S3 keys (the
#      management pair), set TFC workspace vars hetzner_s3_access_key +
#      hetzner_s3_secret_key;
#   2. the next apply un-gates the bucket below and creates it;
#   3. paste the same pair into the `substrate-s3` 1Password item below
#      (one pair serves both consumers -- Hetzner default: each pair is
#      valid for every bucket in the project). Per-key restriction is
#      bucket-policy-based (S3 PutBucketPolicy), not a console toggle --
#      deferred hardening; the install-slice ExternalSecret consumes
#      substrate-s3/credentials/access_key_id + .../secret_access_key.
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
  # Count-gated until the TFC workspace vars carry the Console-generated
  # management keys -- applies stay green before they exist (providers.tf
  # records why configure is offline pre-keys).
  count = var.hetzner_s3_access_key == "" || var.hetzner_s3_secret_key == "" ? 0 : 1

  bucket         = local.substrate_s3_bucket
  acl            = "private"
  object_locking = false
}

# Runtime credentials for substrate's objectstore-plugin sidecars (atelet +
# ate-api-server), hand-pasted from the Console-generated runtime pair.
# synthetic.tf / linear-mcp-oauth placeholder pattern: TF is the
# writer-of-record for the ITEM so the ExternalSecret has a stable target
# from day one; ignore_changes keeps applies from reverting the paste.
resource "onepassword_item" "substrate_s3" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "substrate-s3"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        access_key_id = {
          type  = "CONCEALED"
          value = "placeholder-console-generated-s3-key"
        }
        secret_access_key = {
          type  = "CONCEALED"
          value = "placeholder-console-generated-s3-key"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [section_map]
  }
}
