# The Telegram bot token for the Hermes agent harness (apps/hermes) has no
# Terraform origin -- it is created by hand via Telegram's @BotFather, the same
# situation as Synthetic's API key (see synthetic.tf). Terraform creates the
# 1Password item with placeholder values; the real token is pasted into the
# item by hand afterwards, and the ExternalSecret in
# gitops/clusters/de/hetzner/cluster/apps/hermes/ syncs it into the cluster.
#
# ignore_changes = [section_map] is load-bearing (see synthetic.tf): without
# it, the first apply after the manual paste would revert the item contents
# back to these placeholders.
#
# allowed_user_ids holds the numeric Telegram user ID(s) allowed to talk to the
# bot (AgentHarness telegram channel allowlist). It is also a placeholder --
# fill it with your own user ID (message @userinfobot to get it) or the bot
# would answer anyone who finds it. The harness fails closed until this is a
# real value.
resource "onepassword_item" "hermes_telegram_bot" {
  vault    = data.onepassword_vault.kubernetes.uuid
  title    = "hermes-telegram-bot"
  category = "login"

  section_map = {
    credentials = {
      field_map = {
        token = {
          type  = "CONCEALED"
          value = "REPLACE-ME-with-Telegram-bot-token-from-BotFather"
        }
        allowed_user_ids = {
          type  = "CONCEALED"
          value = "REPLACE-ME-with-numeric-telegram-user-id"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [section_map]
  }
}
