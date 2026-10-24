import { Credential, Plugin, Provider } from "@opencode/plugin"

// Self-hosted LLM gateway integration for opencode v2 (plugin API).
//
// This one plugin owns everything about the gateway:
//
//   1. PROVIDER "gateway" (openai-compatible, https://ai.internal.willpxxr.com/v1)
//      is registered below as a *separate* provider whose model list is
//      cloned live from the built-in "synthetic" provider on every registry
//      rebuild, so it tracks the models.dev catalog automatically. The
//      built-in "synthetic" provider is left untouched for direct access;
//      switch raw <-> gateway in /models (gateway/<model> vs synthetic/<model>).
//
//   2. AUTH: registers the Auth0 PKCE authorization-code method on the
//      "gateway" integration (`opencode auth login gateway` -> "willpxxr
//      SSO (Auth0)") -- the gateway gates access with Auth0 JWTs (llm:use),
//      NOT Synthetic's own key. opencode stores the tokens; the `refresh`
//      hook rotates the access token on expiry (Auth0 refresh-token
//      rotation), so this works on every launch with no shell wrapper or
//      env var.
//
// Canonical home: this repo (.opencode/plugins/); ~/.config/opencode/plugins
// symlinks to it (the V1 `plugin/` dir -- singular -- is gone; v2 only).
//
// The client_id is the public/native PKCE client created by auth0.tf
// (auth0_client.ai_gateway_llm) -- same one scripts/ai-gateway-login.sh
// uses via oauth2c, including the already-registered localhost:9876
// callback and the llm:use scope. Being a public client, the ID is not a
// secret (no client_secret exists -- PKCE replaces it).

const PROVIDER_ID = Provider.ID.make("gateway")
const METHOD_ID = "willpxxr-sso"
const CLIENT_ID = "U78MPGYEqod4OJzSax3HpqJwOgijXQJB"
const ISSUER = "https://auth.willpxxr.com"
const BASE_URL = "https://ai.internal.willpxxr.com/v1"
const AUDIENCE = "https://ai.internal.willpxxr.com"
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

interface Auth0Tokens {
  access_token?: string
  refresh_token?: string
  expires_in?: number
}

async function tokenRequest(body: Record<string, string>): Promise<Auth0Tokens | null> {
  const res = await fetch(`${ISSUER}/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(body),
  })
  if (!res.ok) return null
  return (await res.json()) as Auth0Tokens
}

function oauthCredential(t: Auth0Tokens): Credential.OAuth | null {
  if (!t.access_token || !t.refresh_token) return null
  return {
    type: "oauth",
    methodID: METHOD_ID as Credential.OAuth["methodID"],
    access: t.access_token,
    refresh: t.refresh_token,
    expires: Date.now() + (t.expires_in ?? 3600) * 1000,
  }
}

export default Plugin.define({
  id: "ai-gateway",
  async setup(ctx) {
    // Register the provider first: the "gateway" integration the auth
    // method below attaches to is derived from this provider entry.
    await ctx.provider.transform((editor) => {
      const synthetic = editor.get("synthetic")
      const models = synthetic
        ? [...synthetic.models.values()].map((model) => ({
            ...model,
            providerID: PROVIDER_ID,
          }))
        : []
      editor.add({
        info: {
          ...Provider.Info.empty(PROVIDER_ID),
          name: "willpxxr AI Gateway",
          activation: "enabled",
          package: "@opencode/ai/providers/openai-compatible",
          settings: { baseURL: BASE_URL },
        },
        models,
      })
    })

    await ctx.integration.transform((editor) => {
      editor.method.update({
        integrationID: "gateway",
        method: {
          id: METHOD_ID,
          type: "oauth",
          label: "willpxxr SSO (Auth0)",
        },
        label: () => "willpxxr SSO",
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
            mode: "auto" as const,
            // Runs in opencode's Bun runtime (same as the V1 plugin).
            callback: new Promise<Credential.OAuth>((resolve, reject) => {
              const server = Bun.serve({
                port: CALLBACK_PORT,
                hostname: "127.0.0.1",
                async fetch(req) {
                  const u = new URL(req.url)
                  if (u.pathname !== "/callback") {
                    return new Response("not found", { status: 404 })
                  }
                  const finish = (fn: () => void) => {
                    queueMicrotask(() => server.stop(true))
                    fn()
                  }
                  if (u.searchParams.get("state") !== state) {
                    finish(() => reject(new Error("state mismatch")))
                    return new Response(
                      "State mismatch -- close this tab and try again.",
                      { status: 400 },
                    )
                  }
                  const code = u.searchParams.get("code")
                  if (!code) {
                    const why =
                      u.searchParams.get("error_description") ?? "no code returned"
                    finish(() => reject(new Error(why)))
                    return new Response(
                      `Login failed: ${why}. Close this tab and try again.`,
                      { status: 400 },
                    )
                  }
                  const cred = oauthCredential(await tokenRequest({
                    grant_type: "authorization_code",
                    client_id: CLIENT_ID,
                    code,
                    redirect_uri: REDIRECT_URI,
                    code_verifier: verifier,
                  }))
                  finish(() =>
                    cred ? resolve(cred) : reject(new Error("token exchange failed")),
                  )
                  return new Response(
                    cred
                      ? "Login successful -- you can close this tab and return to opencode."
                      : "Token exchange failed -- close this tab and try again.",
                    { status: cred ? 200 : 400 },
                  )
                },
              })
              setTimeout(() => {
                server.stop(true)
                reject(new Error("login callback timed out"))
              }, CALLBACK_TIMEOUT_MS)
            }),
          }
        },
        refresh: async (credential) => {
          // Auth0 rotation invalidates the refresh token on use, so the
          // new pair opencode persists from this return is the only valid one.
          const cred = oauthCredential(await tokenRequest({
            grant_type: "refresh_token",
            client_id: CLIENT_ID,
            refresh_token: credential.refresh,
          }))
          if (!cred) {
            throw new Error("refresh failed -- run `opencode auth login gateway` again")
          }
          return cred
        },
      })
    })
  },
})
