# "Default workspace" for a created resource isn't guaranteed to resolve
# to the same workspace across different resource types when left
# implicit (observed directly: a guardrail created without workspace_id
# didn't end up applied to a key also created without workspace_id) --
# looking this up explicitly and setting it on both resources below
# removes that ambiguity. A personal account has exactly one workspace,
# so items[0] is reliable here.
data "openrouter_workspaces" "all" {}

# Backend for the self-hosted LLM gateway (gitops:
# apps/ai-gateway-llm/), replacing the earlier OpenCode Go plan --
# OpenRouter's free tier needs no subscription, and this provider lets
# Terraform create a real, scoped API key directly (its `key` attribute is
# Computed+Sensitive, populated only on create) rather than requiring a
# manually-obtained key pasted in by hand.
resource "openrouter_api_key" "gateway" {
  name         = "willpxxr-live-ai-gateway"
  workspace_id = data.openrouter_workspaces.all.items[0].id

  # Confirmed via the provider's own governance example (examples/
  # governance/main.tf): the guardrail must exist before the key is
  # created for it to actually apply -- sharing a workspace_id alone
  # doesn't guarantee that ordering, since without this Terraform could
  # create both in parallel.
  depends_on = [openrouter_guardrail.gateway]
}

# Explicit workspace_id (see the data source comment above) to guarantee
# this actually applies to the api_key above. allowed_models is a hard
# restriction to deepseek-v4 flash/pro specifically -- confirmed via
# OpenRouter's live /models API that neither currently has a $0 :free
# variant, but both are extremely cheap (fractions of a cent per 1K
# tokens), which is why "cost effective" rather than strictly free is
# the framing here. Uses the dated snapshot
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
  workspace_id   = data.openrouter_workspaces.all.items[0].id
  limit_usd      = 5
  reset_interval = "monthly"

  # The four :free entries are genuinely $0/$0 per OpenRouter's live
  # /models pricing -- confirmed via the API, not assumed from the name.
  # Bare :free IDs used here, not canonical_slug -- unlike deepseek above,
  # :free is a distinct pricing-tier selector actually used in API calls,
  # not just an alias for the same dated snapshot. If OpenRouter's
  # provider produces the same plan/apply mismatch seen with deepseek,
  # switch the affected ones to their canonical_slug (confirmed via
  # /models: qwen3-coder:free -> qwen/qwen3-coder-480b-a35b-07-25,
  # nemotron-3-ultra-550b-a55b:free -> ...-20260604).
  allowed_models = [
    "deepseek/deepseek-v4-flash-20260423",
    "deepseek/deepseek-v4-pro-20260423",
    "qwen/qwen3-coder:free",
    "openai/gpt-oss-120b:free",
    "meta-llama/llama-3.3-70b-instruct:free",
    "nvidia/nemotron-3-ultra-550b-a55b:free",
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
