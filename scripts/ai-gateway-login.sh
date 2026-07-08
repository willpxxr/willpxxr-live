#!/usr/bin/env bash
# Logs into a self-hosted AI gateway and stores the resulting access token
# in 1Password (refresh token) and, in --cron mode, a sourceable env file
# (access token) -- see gitops/clusters/de/hetzner/cluster/apps/
# ai-gateway-llm/ and apps/ai-gateway-mcp/, and auth0.tf's
# ai_gateway_llm/ai_gateway_mcp clients, for the infra this talks to.
#
# Interactive mode (default): on first run (no stored refresh token yet)
# opens a browser for the real Auth0 consent screen (PKCE). On every later
# run it tries the stored refresh token first, silently, and only falls
# back to the browser flow if that fails (expired/revoked).
#
# --cron mode: for unattended/headless use (e.g. a crontab entry). Never
# opens a browser -- if the stored refresh token doesn't work, this fails
# loudly instead of hanging waiting for interactive consent that can never
# happen. On success, also writes the access token to a sourceable env
# file (~/.config/opencode/gateway-env.sh by default) so a plain shell
# `env: ["VAR_NAME"]`-style provider config (opencode has no native
# command-substitution for provider credentials, unlike crush/MCP) picks
# up a fresh value on the next new shell/opencode launch.
#
# Auth0 rotates refresh tokens on every use, so the new one always gets
# written back to 1Password -- never reuse a refresh token after this
# script has consumed it.
#
# Usage: scripts/ai-gateway-login.sh <llm|mcp> [--cron]

set -euo pipefail

SERVICE="${1:-}"
CRON_MODE=false
if [[ "${2:-}" == "--cron" ]]; then
  CRON_MODE=true
fi

case "$SERVICE" in
  llm)
    CONFIG_ITEM="ai-gateway-llm-oauth2c"
    TOKEN_ITEM="ai-gateway-llm-token"
    SCOPE="llm:use"
    ENV_VAR_NAME="AI_GATEWAY_LLM_TOKEN"
    ;;
  mcp)
    CONFIG_ITEM="ai-gateway-mcp-oauth2c"
    TOKEN_ITEM="ai-gateway-mcp-token"
    SCOPE="mcp:use"
    ENV_VAR_NAME="AI_GATEWAY_MCP_TOKEN"
    ;;
  *)
    echo "usage: $0 <llm|mcp> [--cron]" >&2
    exit 1
    ;;
esac
CONFIG_VAULT="terraform"
TOKEN_VAULT="terraform"
ENV_FILE="${AI_GATEWAY_ENV_FILE:-$HOME/.config/opencode/gateway-env.sh}"

for bin in oauth2c op jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: $bin is required but not installed" >&2
    exit 1
  fi
done

client_id=$(op read "op://${CONFIG_VAULT}/${CONFIG_ITEM}/client_id")
issuer=$(op read "op://${CONFIG_VAULT}/${CONFIG_ITEM}/issuer")
audience=$(op read "op://${CONFIG_VAULT}/${CONFIG_ITEM}/audience")

# Login item template has a built-in `password` field (CONCEALED) for the
# access token; refresh_token is a custom field we add ourselves, also
# CONCEALED. Building the full field list this way (rather than per-field
# assignment statements) keeps the token values out of command
# arguments/history, per 1Password's own recommendation for sensitive
# values (`op item create --help`).
build_template() {
  local access_token="$1" refresh_token="$2" base_json="$3"
  echo "$base_json" | jq \
    --arg access "$access_token" \
    --arg refresh "$refresh_token" \
    '
    (.fields |= map(if .id == "password" then .value = $access else . end)) |
    if (.fields | any(.id == "refresh_token")) then
      .fields |= map(if .id == "refresh_token" then .value = $refresh else . end)
    else
      .fields += [{
        id: "refresh_token",
        type: "CONCEALED",
        label: "refresh_token",
        value: $refresh
      }]
    end
    '
}

do_full_login() {
  echo "No usable stored refresh token -- opening browser for login..." >&2
  # response-types/response-mode/grant-type/auth-method aren't inferred
  # from --pkce alone -- oauth2c errors without them explicitly set.
  # auth-method=none matches both clients being public/native (no client
  # secret).
  oauth2c "$issuer" \
    --client-id "$client_id" \
    --response-types code \
    --response-mode query \
    --grant-type authorization_code \
    --auth-method none \
    --scopes "openid,${SCOPE}" \
    --audience "$audience" \
    --pkce --silent
}

do_refresh() {
  local refresh_token="$1"
  oauth2c "$issuer" \
    --client-id "$client_id" \
    --grant-type refresh_token \
    --auth-method none \
    --refresh-token "$refresh_token" \
    --silent
}

existing_item=""
stored_refresh_token=""
if existing_item=$(op item get "$TOKEN_ITEM" --vault="$TOKEN_VAULT" --format=json 2>/dev/null); then
  stored_refresh_token=$(echo "$existing_item" | jq -r '.fields[] | select(.id == "refresh_token") | .value // empty')
fi

result=""
if [[ -n "$stored_refresh_token" ]]; then
  echo "Refreshing using the stored refresh token..." >&2
  if ! result=$(do_refresh "$stored_refresh_token"); then
    if [[ "$CRON_MODE" == true ]]; then
      echo "error: stored refresh token no longer works, and --cron mode can't open a browser to re-authenticate. Run '$0 $SERVICE' interactively once to fix this." >&2
      exit 1
    fi
    echo "Stored refresh token no longer works, falling back to full login." >&2
    result=""
  fi
fi

if [[ -z "$result" ]]; then
  if [[ "$CRON_MODE" == true ]]; then
    echo "error: no usable stored refresh token, and --cron mode can't open a browser. Run '$0 $SERVICE' interactively once first." >&2
    exit 1
  fi
  result=$(do_full_login)
fi

access_token=$(echo "$result" | jq -r '.access_token')
new_refresh_token=$(echo "$result" | jq -r '.refresh_token')

if [[ -z "$access_token" || "$access_token" == "null" ]]; then
  echo "error: no access_token in oauth2c's response" >&2
  exit 1
fi

if [[ -n "$existing_item" ]]; then
  template=$(build_template "$access_token" "$new_refresh_token" "$existing_item")
  op item edit "$TOKEN_ITEM" --vault="$TOKEN_VAULT" --template=<(echo "$template") >/dev/null
else
  base_json=$(op item template get Login)
  template=$(build_template "$access_token" "$new_refresh_token" "$base_json")
  echo "$template" | op item create --vault="$TOKEN_VAULT" --title="$TOKEN_ITEM" - >/dev/null
fi

if [[ "$CRON_MODE" == true ]]; then
  mkdir -p "$(dirname "$ENV_FILE")"
  # 0600: this file holds a live bearer token in plaintext, unlike the
  # 1Password items above.
  umask 077
  {
    echo "# Generated by scripts/ai-gateway-login.sh -- do not edit by hand."
    echo "export ${ENV_VAR_NAME}=\"${access_token}\""
  } >"$ENV_FILE"
  echo "Done -- wrote a fresh token to ${ENV_FILE} (\$${ENV_VAR_NAME}). Source it in new shells, or add to your shell profile." >&2
else
  echo "Done -- via op read op://${TOKEN_VAULT}/${TOKEN_ITEM}/password." >&2
fi
