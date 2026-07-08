# Dedicated workspace for the hardened/paid models -- symmetric with
# openrouter_workspace.free below, rather than this side implicitly
# using whatever workspace pre-existed on the account (the earlier
# version of this file used a data.openrouter_workspaces lookup instead,
# which wasn't a real dedicated workspace, just the account's default).
resource "openrouter_workspace" "hardened" {
  name        = "willpxxr-live-ai-gateway-hardened"
  slug        = "willpxxr-live-ai-gateway-hardened"
  description = "Cost-effective (not free) models for the self-hosted LLM gateway, isolated from the free-tier workspace -- gated behind llm:use alone in auth0.tf, no llm-free:use needed."
}

# Backend for the self-hosted LLM gateway (gitops:
# apps/ai-gateway-llm/), replacing the earlier OpenCode Go plan --
# OpenRouter's free tier needs no subscription, and this provider lets
# Terraform create a real, scoped API key directly (its `key` attribute is
# Computed+Sensitive, populated only on create) rather than requiring a
# manually-obtained key pasted in by hand.
resource "openrouter_api_key" "gateway" {
  name         = "willpxxr-live-ai-gateway"
  workspace_id = openrouter_workspace.hardened.id

  # Confirmed via the provider's own governance example (examples/
  # governance/main.tf): the guardrail must exist before the key is
  # created for it to actually apply -- sharing a workspace_id alone
  # doesn't guarantee that ordering, since without this Terraform could
  # create both in parallel.
  depends_on = [openrouter_guardrail.gateway]
}

# allowed_models is a hard restriction to deepseek-v4 flash/pro
# specifically -- confirmed via OpenRouter's live /models API that
# neither currently has a $0 :free variant, but both are extremely cheap
# (fractions of a cent per 1K tokens), which is why "cost effective"
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
  workspace_id   = openrouter_workspace.hardened.id
  limit_usd      = 5
  reset_interval = "monthly"

  # Defense in depth on top of allowed_models -- guarantees these
  # deepseek models never route to a data-retaining/training endpoint,
  # independent of whatever the account-wide privacy setting ends up
  # being (which the free workspace's models need enabled). Guardrails
  # can only ever be more restrictive than that account-wide baseline,
  # never less, so this is a real, enforced narrowing, not just intent.
  enforce_zdr_anthropic = true
  enforce_zdr_google    = true
  enforce_zdr_openai    = true
  enforce_zdr_other     = true

  # deepseek only -- the free models moved to their own workspace/guardrail
  # below (openrouter_guardrail.gateway_free), gated behind the gateway's
  # separate llm-free:use Auth0 scope (see auth0.tf and gitops:
  # apps/ai-gateway-llm/ai-gateway-route-free.yaml +
  # security-policy-free.yaml). Kept as separate workspaces (not just a
  # shared guardrail's allowed_models) for real operational isolation --
  # separate API keys, separate spending/usage tracking -- not to work
  # around OpenRouter's privacy/data policy, which is account-wide and
  # NOT configurable per-workspace (confirmed via OpenRouter's own docs)
  # -- the free models still separately need data publication enabled at
  # openrouter.ai/settings/privacy regardless of which workspace calls
  # them.
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

# Separate workspace for the privacy-sensitive free models (see
# allowed_models comment above) -- real operational isolation from the
# hardened deepseek workspace: its own API key, spending/usage tracking,
# and guardrail, even though the underlying account-wide privacy policy
# is shared regardless of workspace.
resource "openrouter_workspace" "free" {
  name        = "willpxxr-live-ai-gateway-free"
  slug        = "willpxxr-live-ai-gateway-free"
  description = "Free-tier models for the self-hosted LLM gateway, isolated from the hardened deepseek workspace -- gated behind llm-free:use in auth0.tf."
}

# Same PII redaction + prompt injection defense as the hardened
# guardrail above -- user explicitly chose to keep full protection here
# rather than relax it, since redaction/blocking cost nothing regardless
# of the underlying models being free. limit_usd is a small nominal
# backstop (not a real cost control, since every allowed model here is
# genuinely $0/$0) purely in case OpenRouter's pricing changes
# unexpectedly or the allowlist is ever bypassed.
resource "openrouter_guardrail" "gateway_free" {
  name           = "willpxxr-live-ai-gateway-free"
  description    = "Model allowlist + PII redaction + prompt injection defense for the self-hosted LLM gateway's free-tier models (ai.tailb40090.ts.net)."
  workspace_id   = openrouter_workspace.free.id
  limit_usd      = 1
  reset_interval = "monthly"

  # Canonical_slug used for qwen3-coder/nemotron-3-ultra/hy3, bare :free
  # id for openai/meta-llama -- same distinction as the hardened
  # guardrail's earlier deepseek fix: OpenRouter's provider resolves
  # allowed_models to canonical form internally, and only the entries
  # whose canonical_slug differs from their bare id hit the "inconsistent
  # result after apply" bug.
  allowed_models = [
    "qwen/qwen3-coder-480b-a35b-07-25",
    "openai/gpt-oss-120b:free",
    "meta-llama/llama-3.3-70b-instruct:free",
    "nvidia/nemotron-3-ultra-550b-a55b-20260604",
    "tencent/hy3-20260706",
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

resource "openrouter_api_key" "gateway_free" {
  name         = "willpxxr-live-ai-gateway-free"
  workspace_id = openrouter_workspace.free.id

  # Same ordering fix as openrouter_api_key.gateway above.
  depends_on = [openrouter_guardrail.gateway_free]
}

resource "onepassword_item" "openrouter_free" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "openrouter-free"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        api_key = {
          type  = "CONCEALED"
          value = openrouter_api_key.gateway_free.key
        }
      }
    }
  }
}
