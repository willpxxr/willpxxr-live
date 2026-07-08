#!/usr/bin/env bash
# Logs into a self-hosted AI gateway and stores the resulting access token
# in 1Password, where crush.json reads it from via `op read` at request
# time -- see gitops/clusters/de/hetzner/cluster/apps/ai-gateway-llm/ and
# apps/ai-gateway-mcp/, and auth0.tf's ai_gateway_llm/ai_gateway_mcp
# clients, for the infra this talks to.
#
# On first run (no stored refresh token yet) this opens a browser for the
# real Auth0 consent screen (PKCE). On every later run it tries the stored
# refresh token first, silently, and only falls back to the browser flow if
# that fails (expired/revoked). Auth0 rotates refresh tokens on every use,
# so the new one always gets written back -- never reuse a refresh token
# after this script has consumed it.
#
# Usage: scripts/ai-gateway-login.sh <llm|mcp>

set -euo pipefail

SERVICE="${1:-}"
case "$SERVICE" in
  llm)
    CONFIG_ITEM="ai-gateway-llm-oauth2c"
    TOKEN_ITEM="ai-gateway-llm-token"
    SCOPE="llm:use"
    ;;
  mcp)
    CONFIG_ITEM="ai-gateway-mcp-oauth2c"
    TOKEN_ITEM="ai-gateway-mcp-token"
    SCOPE="mcp:use"
    ;;
  *)
    echo "usage: $0 <llm|mcp>" >&2
    exit 1
    ;;
esac
CONFIG_VAULT="terraform"
TOKEN_VAULT="terraform"

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
    echo "Stored refresh token no longer works, falling back to full login." >&2
    result=""
  fi
fi

if [[ -z "$result" ]]; then
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

echo "Done -- crush (via op read op://${TOKEN_VAULT}/${TOKEN_ITEM}/password) now has a fresh token." >&2
