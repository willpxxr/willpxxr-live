# Better Stack Telemetry source for the cluster-wide OTel Collector
# (gitops: apps/otel-collector-agent/, apps/otel-collector-gateway/). Using
# the provider (rather than pasting a token created by hand in the
# dashboard) means the source token and ingesting host are never typed
# in manually -- both are Computed+Sensitive attributes populated only on
# create, written straight into the same 1Password vault the cluster's
# ExternalSecrets already read from.
resource "logtail_source" "otel_collector" {
  name     = "willpxxr-live-otel-collector"
  platform = "open_telemetry"
}

resource "onepassword_item" "betterstack_otel" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "betterstack-otel"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        source_token = {
          type  = "CONCEALED"
          value = logtail_source.otel_collector.token
        }
        ingesting_host = {
          type  = "STRING"
          value = logtail_source.otel_collector.ingesting_host
        }
      }
    }
  }
}
