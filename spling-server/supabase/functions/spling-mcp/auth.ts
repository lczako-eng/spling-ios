// ============================================================================
// OAuth 2.1 + Dynamic Client Registration.
//
// This file exists for a usability reason before a technical one.
//
// The shared bearer token works, but it makes Spling a programmer's product:
// to use it you open developer settings and paste a 64-character secret. The
// people this is built for — someone with aphasia, an AAC user, an 80-year-old,
// a settlement client on their second week in the country — will not do that,
// and shouldn't have to. OAuth replaces the paste with a "Sign in" button they
// have pressed a hundred times before.
//
// It is also a hard ChatGPT requirement and the entry fee for being listed in
// an assistant's connector directory, which is the only path to installation
// being a single click. So the same change fixes the usability wall and the
// distribution wall at once.
//
// What is implemented here:
//   - RFC 8414  Authorization Server Metadata      (/.well-known/oauth-authorization-server)
//   - RFC 9728  Protected Resource Metadata        (/.well-known/oauth-protected-resource)
//   - RFC 7591  Dynamic Client Registration        (/register)
//   - RFC 7636  PKCE, S256 only — plain is refused
//   - Authorization Code grant + refresh, short-lived opaque access tokens
//
// Deliberately NOT implemented: implicit grant, password grant, plain PKCE.
// OAuth 2.1 removes them and this server is new — there is nothing to be
// backwards-compatible with.
//
// The token store is Postgres (migration 004). Tokens are stored hashed, so a
// database leak does not hand over live sessions.
// ============================================================================

// deno-lint-ignore no-explicit-any
const env = (k: string): string => (globalThis as any).Deno?.env?.get(k) ?? "";

export const ACCESS_TTL_S = 60 * 60;            // 1 hour
export const REFRESH_TTL_S = 60 * 60 * 24 * 60; // 60 days
export const CODE_TTL_S = 60 * 5;               // 5 minutes — codes are single use

export const SCOPES = ["spling.order", "spling.profile", "spling.history"] as const;

export interface TokenClaims {
  subject: string;
  client_id: string;
  scopes: string[];
}

// ---------------------------------------------------------------------------
// crypto helpers
// ---------------------------------------------------------------------------

export function randomToken(bytes = 32): string {
  const b = new Uint8Array(bytes);
  crypto.getRandomValues(b);
  return base64url(b);
}

export function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const byte of bytes) s += String.fromCharCode(byte);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Tokens are stored hashed — a leaked table must not be a set of live sessions. */
export async function sha256(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return base64url(new Uint8Array(digest));
}

/**
 * PKCE S256 verification. `plain` is not accepted: it offers no protection
 * against an intercepted authorization code, and OAuth 2.1 drops it.
 */
export async function verifyPkce(verifier: string, challenge: string, method: string): Promise<boolean> {
  if (method !== "S256") return false;
  if (!verifier || verifier.length < 43 || verifier.length > 128) return false;
  return (await sha256(verifier)) === challenge;
}

/** Constant-time comparison, so a wrong secret cannot be found byte by byte. */
export function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// ---------------------------------------------------------------------------
// validation — pure, so it is testable without a database
// ---------------------------------------------------------------------------

export interface ClientRegistration {
  client_name?: string;
  redirect_uris: string[];
  grant_types?: string[];
  token_endpoint_auth_method?: string;
  scope?: string;
}

export class OAuthError extends Error {
  code: string;
  status: number;
  constructor(code: string, message: string, status = 400) {
    super(message);
    this.name = "OAuthError";
    this.code = code;
    this.status = status;
  }
}

/**
 * A redirect URI must be absolute, and must be https unless it is loopback.
 * Wildcards and fragments are refused — an open redirect here would hand an
 * authorization code to whoever asked for it.
 */
export function validateRedirectUri(uri: string): void {
  let u: URL;
  try { u = new URL(uri); } catch {
    throw new OAuthError("invalid_redirect_uri", `"${uri}" is not an absolute URI.`);
  }
  if (u.hash) throw new OAuthError("invalid_redirect_uri", "A redirect URI may not contain a fragment.");
  if (uri.includes("*")) throw new OAuthError("invalid_redirect_uri", "Wildcard redirect URIs are not accepted.");

  const loopback = u.hostname === "localhost" || u.hostname === "127.0.0.1" || u.hostname === "[::1]";
  if (u.protocol === "http:" && !loopback) {
    throw new OAuthError("invalid_redirect_uri", "A redirect URI must use https, except on loopback.");
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") {
    // Native apps use custom schemes; allowed, but they must still be absolute.
    if (!u.protocol.endsWith(":") || u.protocol.length < 3) {
      throw new OAuthError("invalid_redirect_uri", "Unsupported redirect URI scheme.");
    }
  }
}

export function validateRegistration(body: unknown): ClientRegistration {
  const b = (body ?? {}) as Record<string, unknown>;
  const uris = b.redirect_uris;
  if (!Array.isArray(uris) || uris.length === 0) {
    throw new OAuthError("invalid_client_metadata", "redirect_uris is required and must be a non-empty array.");
  }
  if (uris.length > 10) {
    throw new OAuthError("invalid_client_metadata", "Too many redirect URIs.");
  }
  for (const u of uris) {
    if (typeof u !== "string") throw new OAuthError("invalid_client_metadata", "Each redirect URI must be a string.");
    validateRedirectUri(u);
  }

  const grants = (b.grant_types as string[]) ?? ["authorization_code", "refresh_token"];
  for (const g of grants) {
    if (g !== "authorization_code" && g !== "refresh_token") {
      throw new OAuthError("invalid_client_metadata", `Grant type "${g}" is not supported. OAuth 2.1 removes it.`);
    }
  }

  return {
    client_name: typeof b.client_name === "string" ? b.client_name.slice(0, 200) : "Unnamed client",
    redirect_uris: uris as string[],
    grant_types: grants,
    token_endpoint_auth_method: (b.token_endpoint_auth_method as string) ?? "none",
    scope: typeof b.scope === "string" ? b.scope : SCOPES.join(" "),
  };
}

/** Requested scopes narrowed to what this server actually grants. */
export function narrowScopes(requested?: string): string[] {
  if (!requested) return [...SCOPES];
  const want = requested.split(/\s+/).filter(Boolean);
  const granted = want.filter((s) => (SCOPES as readonly string[]).includes(s));
  return granted.length ? granted : [...SCOPES];
}

/** An exact match against a registered URI. No prefix matching, ever. */
export function pickRedirectUri(registered: string[], requested?: string): string {
  if (!requested) {
    if (registered.length === 1) return registered[0];
    throw new OAuthError("invalid_request", "redirect_uri is required when a client registered more than one.");
  }
  if (!registered.includes(requested)) {
    throw new OAuthError("invalid_request", "redirect_uri does not exactly match a registered URI.");
  }
  return requested;
}

// ---------------------------------------------------------------------------
// discovery documents
// ---------------------------------------------------------------------------

export function authorizationServerMetadata(issuer: string) {
  return {
    issuer,
    authorization_endpoint: `${issuer}/authorize`,
    token_endpoint: `${issuer}/token`,
    registration_endpoint: `${issuer}/register`,
    revocation_endpoint: `${issuer}/revoke`,
    scopes_supported: [...SCOPES],
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code", "refresh_token"],
    code_challenge_methods_supported: ["S256"],           // no 'plain'
    token_endpoint_auth_methods_supported: ["none", "client_secret_post"],
    service_documentation: "https://spling.org/accessibility.html",
  };
}

export function protectedResourceMetadata(issuer: string) {
  return {
    resource: issuer,
    authorization_servers: [issuer],
    scopes_supported: [...SCOPES],
    bearer_methods_supported: ["header"],
  };
}

/**
 * The 401 that starts the whole flow. Without this header an assistant cannot
 * discover where to send the user to sign in, and falls back to asking a human
 * for a token — which is the failure this file exists to remove.
 */
export function wwwAuthenticate(issuer: string): string {
  return `Bearer resource_metadata="${issuer}/.well-known/oauth-protected-resource"`;
}

export function issuerFrom(req: Request): string {
  const url = new URL(req.url);
  const forwardedHost = req.headers.get("x-forwarded-host");
  const host = forwardedHost || url.host;
  const proto = req.headers.get("x-forwarded-proto") || (host.startsWith("localhost") ? "http" : "https");
  const base = `${proto}://${host}`;
  // Supabase serves functions under /functions/v1/<name>; keep that prefix so
  // the advertised endpoints are reachable exactly as written.
  const m = url.pathname.match(/^(.*?\/functions\/v1\/[^/]+)/);
  return m ? base + m[1] : base;
}

export const SUPPORTS_LEGACY_BEARER = () => env("SPLING_BEARER").length > 0;
