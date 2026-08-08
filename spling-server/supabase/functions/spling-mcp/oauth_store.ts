// ============================================================================
// OAuth persistence (migration 004). Service-role only; never reachable from a
// client. Tokens arrive here already hashed — this module never sees a live
// secret it could log.
// ============================================================================

import { sha256 } from "./auth.ts";

// deno-lint-ignore no-explicit-any
const env = (k: string): string => (globalThis as any).Deno?.env?.get(k) ?? "";
const SUPABASE_URL = env("SUPABASE_URL");
const SERVICE_KEY = env("SUPABASE_SERVICE_ROLE_KEY");

async function pg(path: string, init: RequestInit = {}): Promise<any> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
      Prefer: "return=representation",
      ...(init.headers ?? {}),
    },
  });
  const text = await res.text();
  const body = text ? JSON.parse(text) : null;
  if (!res.ok) throw new Error(`oauth db ${path} ${res.status}: ${JSON.stringify(body)}`);
  return body;
}

export interface ClientRow {
  client_id: string;
  client_secret_hash: string | null;
  client_name: string;
  redirect_uris: string[];
  scope: string;
}

export async function createClient(row: {
  client_id: string;
  client_secret_hash: string | null;
  client_name: string;
  redirect_uris: string[];
  grant_types: string[];
  scope: string;
}): Promise<ClientRow> {
  const out = await pg("oauth_clients", { method: "POST", body: JSON.stringify(row) });
  return out[0];
}

export async function getClient(clientId: string): Promise<ClientRow | null> {
  const rows = await pg(
    `oauth_clients?client_id=eq.${encodeURIComponent(clientId)}&select=client_id,client_secret_hash,client_name,redirect_uris,scope&limit=1`,
  );
  return rows?.[0] ?? null;
}

// ---------------------------------------------------------------------------
// authorization codes
// ---------------------------------------------------------------------------

export async function storeCode(input: {
  code: string;
  client_id: string;
  subject: string;
  redirect_uri: string;
  scopes: string[];
  code_challenge: string;
  ttlSeconds: number;
}): Promise<void> {
  await pg("oauth_codes", {
    method: "POST",
    body: JSON.stringify({
      code_hash: await sha256(input.code),
      client_id: input.client_id,
      subject: input.subject,
      redirect_uri: input.redirect_uri,
      scopes: input.scopes,
      code_challenge: input.code_challenge,
      code_challenge_method: "S256",
      expires_at: new Date(Date.now() + input.ttlSeconds * 1000).toISOString(),
    }),
  });
}

export interface CodeRow {
  code_hash: string;
  client_id: string;
  subject: string;
  redirect_uri: string;
  scopes: string[];
  code_challenge: string;
  expires_at: string;
  consumed_at: string | null;
}

export async function takeCode(code: string): Promise<CodeRow | null> {
  const hash = await sha256(code);
  const rows = await pg(`oauth_codes?code_hash=eq.${encodeURIComponent(hash)}&select=*&limit=1`);
  return rows?.[0] ?? null;
}

export async function markCodeConsumed(codeHash: string): Promise<void> {
  await pg(`oauth_codes?code_hash=eq.${encodeURIComponent(codeHash)}`, {
    method: "PATCH",
    body: JSON.stringify({ consumed_at: new Date().toISOString() }),
  });
}

// ---------------------------------------------------------------------------
// tokens
// ---------------------------------------------------------------------------

export async function storeToken(input: {
  token: string;
  kind: "access" | "refresh";
  client_id: string;
  subject: string;
  scopes: string[];
  grant_id: string;
  ttlSeconds: number;
}): Promise<void> {
  await pg("oauth_tokens", {
    method: "POST",
    body: JSON.stringify({
      token_hash: await sha256(input.token),
      kind: input.kind,
      client_id: input.client_id,
      subject: input.subject,
      scopes: input.scopes,
      grant_id: input.grant_id,
      expires_at: new Date(Date.now() + input.ttlSeconds * 1000).toISOString(),
    }),
  });
}

export interface TokenRow {
  token_hash: string;
  kind: string;
  client_id: string;
  subject: string;
  scopes: string[];
  grant_id: string;
  expires_at: string;
  revoked_at: string | null;
}

export async function findToken(token: string, kind: "access" | "refresh"): Promise<TokenRow | null> {
  const hash = await sha256(token);
  const rows = await pg(
    `oauth_tokens?token_hash=eq.${encodeURIComponent(hash)}&kind=eq.${kind}&select=*&limit=1`,
  );
  const row = rows?.[0];
  if (!row) return null;
  if (row.revoked_at) return null;
  if (new Date(row.expires_at).getTime() <= Date.now()) return null;
  return row;
}

export async function revokeToken(token: string): Promise<void> {
  const hash = await sha256(token);
  await pg(`oauth_tokens?token_hash=eq.${encodeURIComponent(hash)}`, {
    method: "PATCH",
    body: JSON.stringify({ revoked_at: new Date().toISOString() }),
  });
}

/**
 * Revoke an entire grant family. Used when a refresh token is replayed — that
 * means either the client is buggy or a token was stolen, and in both cases the
 * safe move is to end the session rather than guess which.
 */
export async function revokeGrant(grantId: string): Promise<void> {
  await pg(`oauth_tokens?grant_id=eq.${encodeURIComponent(grantId)}&revoked_at=is.null`, {
    method: "PATCH",
    body: JSON.stringify({ revoked_at: new Date().toISOString() }),
  });
}
