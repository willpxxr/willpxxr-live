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

# Credential for the MCP gateway's Better Stack backend (gitops:
# apps/ai-gateway-mcp/), which proxies to https://mcp.betterstack.com and
# needs its own bearer token distinct from the Auth0 token clients present
# to the gateway itself. Better Stack has no Terraform-manageable or
# read-only-scoped API token resource (confirmed against the logtail
# provider's full resource list and Better Stack's own token docs --
# tokens are either global or team-scoped, created only via the
# dashboard), so this deliberately reuses var.betterstack_api_token
# (the same token already authenticating the logtail provider above)
# rather than requiring a second manually-created credential.
resource "onepassword_item" "betterstack_mcp" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "betterstack-mcp"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        api_token = {
          type  = "CONCEALED"
          value = var.betterstack_api_token
        }
      }
    }
  }
}
