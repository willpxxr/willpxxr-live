import type { Plugin } from "@opencode-ai/plugin"

// OAuth (Auth0, PKCE authorization-code flow) for the self-hosted LLM
// gateway (ai.tailb40090.ts.net), registered as an auth method on the
// built-in "synthetic" provider (models.dev id), which opencode.jsonc
// repoints at the gateway. Usage: `opencode auth login synthetic` ->
// pick "willpxxr SSO (Auth0)" -> browser consent -> done. opencode
// stores the OAuth credential itself; `loader` below silently refreshes
// the access token on expiry using the stored refresh token, so this
// works on every launch with no shell wrapper or env var.
//
// Canonical home: this repo (.opencode/); ~/.config/opencode/plugin/
// symlinks to this file.
//
// The client_id is the public/native PKCE client created by auth0.tf
// (auth0_client.ai_gateway_llm) -- same one scripts/ai-gateway-login.sh
// uses via oauth2c, including the already-registered localhost:9876
// callback and the llm:use scope. Being a public client, the ID is not
// a secret (no client_secret exists -- PKCE replaces it).
const CLIENT_ID = "U78MPGYEqod4OJzSax3HpqJwOgijXQJB"
const ISSUER = "https://auth.willpxxr.com"
const AUDIENCE = "https://ai.tailb40090.ts.net"
const SCOPE = "openid offline_access llm:use"
const CALLBACK_PORT = 9876
const REDIRECT_URI = `http://localhost:${CALLBACK_PORT}/callback`
// How long the callback listener waits for the user to finish in the
// browser before giving up (the TUI prompt can otherwise hang forever).
const CALLBACK_TIMEOUT_MS = 120_000

function base64url(buf: ArrayBuffer): string {
  return btoa(String.fromCharCode(...new Uint8Array(buf)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "")
}

function randomBase64url(bytes: number): string {
  const buf = new Uint8Array(bytes)
  crypto.getRandomValues(buf)
  return base64url(buf.buffer)
}

async function tokenRequest(body: Record<string, string>) {
  const res = await fetch(`${ISSUER}/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(body),
  })
  if (!res.ok) return null
  const t = (await res.json()) as {
    access_token?: string
    refresh_token?: string
    expires_in?: number
  }
  if (!t.access_token || !t.refresh_token) return null
  return {
    access: t.access_token,
    refresh: t.refresh_token,
    expires: Date.now() + (t.expires_in ?? 3600) * 1000,
  }
}

export default (async ({ client }) => ({
  auth: {
    provider: "synthetic",
    loader: async (auth) => {
      const a = await auth()
      if (a.type !== "oauth") return {}
      // Still valid (with a 60s margin) -- hand the access token to the
      // OpenAI-compatible provider as its bearer.
      if (Date.now() < a.expires - 60_000) return { apiKey: a.access }
      // Expired: rotate the refresh token (Auth0 rotation invalidates
      // the old one on use, so persist the new pair immediately). A
      // failure here falls back to {} so opencode surfaces the need to
      // `opencode auth login synthetic` again.
      const next = await tokenRequest({
        grant_type: "refresh_token",
        client_id: CLIENT_ID,
        refresh_token: a.refresh,
      })
      if (!next) return {}
      await client.auth.set({
        path: { id: "synthetic" },
        body: { type: "oauth", ...next },
      })
      return { apiKey: next.access }
    },
    methods: [
      {
        type: "oauth",
        label: "willpxxr SSO (Auth0)",
        authorize: async () => {
          const verifier = randomBase64url(32)
          const challenge = base64url(
            await crypto.subtle.digest(
              "SHA-256",
              new TextEncoder().encode(verifier),
            ),
          )
          const state = randomBase64url(16)
          const url =
            `${ISSUER}/authorize?` +
            new URLSearchParams({
              response_type: "code",
              client_id: CLIENT_ID,
              redirect_uri: REDIRECT_URI,
              scope: SCOPE,
              audience: AUDIENCE,
              code_challenge: challenge,
              code_challenge_method: "S256",
              state,
              // Same live-confirmed reason as scripts/ai-gateway-login.sh:
              // without forced consent, Auth0 can skip issuing a refresh
              // token entirely on repeat logins.
              prompt: "consent",
            })
          return {
            url,
            instructions:
              "Complete sign-in with your willpxxr account in the browser window that opens.",
            method: "auto",
            callback: () =>
              new Promise((resolve) => {
                const server = Bun.serve({
                  port: CALLBACK_PORT,
                  hostname: "127.0.0.1",
                  async fetch(req) {
                    const u = new URL(req.url)
                    if (u.pathname !== "/callback") {
                      return new Response("not found", { status: 404 })
                    }
                    const finish = (result: any) => {
                      queueMicrotask(() => server.stop(true))
                      resolve(result)
                    }
                    if (u.searchParams.get("state") !== state) {
                      finish({ type: "failed" })
                      return new Response(
                        "State mismatch -- close this tab and try again.",
                        { status: 400 },
                      )
                    }
                    const code = u.searchParams.get("code")
                    if (!code) {
                      finish({ type: "failed" })
                      return new Response(
                        `Login failed: ${u.searchParams.get("error_description") ?? "no code returned"}. Close this tab and try again.`,
                        { status: 400 },
                      )
                    }
                    const tokens = await tokenRequest({
                      grant_type: "authorization_code",
                      client_id: CLIENT_ID,
                      code,
                      redirect_uri: REDIRECT_URI,
                      code_verifier: verifier,
                    })
                    finish(
                      tokens
                        ? { type: "success", ...tokens }
                        : { type: "failed" },
                    )
                    return new Response(
                      tokens
                        ? "Login successful -- you can close this tab and return to opencode."
                        : "Token exchange failed -- close this tab and try again.",
                      { status: tokens ? 200 : 400 },
                    )
                  },
                })
                setTimeout(() => {
                  server.stop(true)
                  resolve({ type: "failed" })
                }, CALLBACK_TIMEOUT_MS)
              }),
          }
        },
      },
    ],
  },
})) satisfies Plugin
