# Backend for the self-hosted LLM gateway (gitops:
# apps/ai-gateway-llm/), replacing the earlier OpenCode Go plan --
# OpenRouter's free tier needs no subscription, and this provider lets
# Terraform create a real, scoped API key directly (its `key` attribute is
# Computed+Sensitive, populated only on create) rather than requiring a
# manually-obtained key pasted in by hand.
resource "openrouter_api_key" "gateway" {
  name = "willpxxr-live-ai-gateway"
}

resource "onepassword_item" "openrouter" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "openrouter"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        api_key = {
          type  = "CONCEALED"
          value = openrouter_api_key.gateway.key
        }
      }
    }
  }
}
