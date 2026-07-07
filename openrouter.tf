# Backend for the self-hosted LLM gateway (gitops:
# apps/ai-gateway-llm/), replacing the earlier OpenCode Go plan --
# OpenRouter's free tier needs no subscription, and this provider lets
# Terraform create a real, scoped API key directly (its `key` attribute is
# Computed+Sensitive, populated only on create) rather than requiring a
# manually-obtained key pasted in by hand.
resource "openrouter_api_key" "gateway" {
  name = "willpxxr-live-ai-gateway"
}

# Safety net for the personal AI gateway: applies to the default
# workspace (no workspace_id set, matching the API key above -- neither
# specifies one). allowed_models is a hard restriction to deepseek-v4
# flash/pro specifically -- confirmed via OpenRouter's live /models API
# that neither currently has a $0 :free variant, but both are extremely
# cheap (fractions of a cent per 1K tokens), which is why "cost effective"
# rather than strictly free is the framing here. Uses the dated snapshot
# IDs (not the bare alias) since OpenRouter resolves allowed_models to
# the specific dated model internally -- specifying the bare alias caused
# a plan/apply mismatch (planned the alias, actual came back dated).
# Needs manual updates if OpenRouter reassigns the dated snapshot or the
# model lineup changes. limit_usd is a backstop on top of that, plus PII
# redaction on common sensitive patterns. "redact" rather than "block"
# for the PII filters so a false-positive match (e.g. code that happens
# to look like an SSN) scrubs the match rather than failing the whole
# request outright.
#
# Prompt injection defense is separate and set to "block" -- this is a
# coding agent that processes tool outputs and file contents, not just
# what you type, exactly where hidden injected instructions get smuggled
# in, so outright blocking is warranted rather than just flagging.
# scan_scope=all_messages rather than the default user_only for the same
# reason -- the risk is specifically in non-user (tool/file) content.
resource "openrouter_guardrail" "gateway" {
  name           = "willpxxr-live-ai-gateway"
  description    = "Model allowlist + spending cap + PII redaction + prompt injection defense for the self-hosted LLM gateway (ai.tailb40090.ts.net)."
  limit_usd      = 5
  reset_interval = "monthly"

  allowed_models = [
    "deepseek/deepseek-v4-flash-20260423",
    "deepseek/deepseek-v4-pro-20260423",
  ]

  content_filter_builtins = [
    { slug = "email", action = "redact" },
    { slug = "phone", action = "redact" },
    { slug = "ssn", action = "redact" },
    { slug = "credit-card", action = "redact" },
    { slug = "ip-address", action = "redact" },
    { slug = "person-name", action = "redact" },
    { slug = "address", action = "redact" },
    { slug = "regex-prompt-injection", action = "block", scan_scope = "all_messages" },
  ]
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
