#!/usr/bin/env bash
# apiKeyHelper for Claude Code (.claude/settings.local.json in this repo) --
# refreshes the self-hosted AI gateway's LLM token and prints it to stdout,
# which Claude Code sends as both X-Api-Key and Authorization: Bearer on
# every model request. Re-invoked automatically by Claude Code (every
# CLAUDE_CODE_API_KEY_HELPER_TTL_MS, default ~5 minutes, or on a 401),
# so this handles token refresh transparently during a long session --
# unlike a plain env var, which Claude Code only reads once at process
# start. See scripts/ai-gateway-login.sh and gitops/clusters/de/hetzner/
# cluster/apps/ai-gateway-llm/ai-gateway-route-anthropic.yaml for the
# infra this talks to.
#
# Must print ONLY the token to stdout -- no other output, since the
# entire stdout becomes the header value.

set -euo pipefail

~/source/willpxxr-live/scripts/ai-gateway-login.sh llm >&2
op read "op://terraform/ai-gateway-llm-token/password"
