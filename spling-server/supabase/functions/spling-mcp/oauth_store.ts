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
// pending authorizations (migration 005)
//
// The person leaves for Google or Apple mid-flow, so the request has to survive
// without them. Keeping it server-side also closes a hole the old hidden-field
// consent form had: the client's PKCE challenge and redirect URI used to be
// re-posted by the browser, which meant a page in the middle could swap them.
// Now they are read back from the row the GET created, and the only thing the
// browser carries is an unguessable reference.
// ---------------------------------------------------------------------------

export interface PendingRow {
  rid_hash: string;
  client_id: string;
  client_name: string;
  redirect_uri: string;
  state: string;
  scopes: string[];
  code_challenge: string;
  provider_verifier: string;
  subject: string | null;
  expires_at: string;
  consumed_at: string | null;
}

export async function storePending(input: {
  rid: string;
  client_id: string;
  client_name: string;
  redirect_uri: string;
  state: string;
  scopes: string[];
  code_challenge: string;
  provider_verifier: string;
  ttlSeconds: number;
}): Promise<void> {
  await pg("oauth_pending", {
    method: "POST",
    body: JSON.stringify({
      rid_hash: await sha256(input.rid),
      client_id: input.client_id,
      client_name: input.client_name,
      redirect_uri: input.redirect_uri,
      state: input.state,
      scopes: input.scopes,
      code_challenge: input.code_challenge,
      provider_verifier: input.provider_verifier,
      expires_at: new Date(Date.now() + input.ttlSeconds * 1000).toISOString(),
    }),
  });
}

/** Live rows only: expired or already-redeemed references read as absent. */
export async function getPending(rid: string): Promise<PendingRow | null> {
  const hash = await sha256(rid);
  const rows = await pg(`oauth_pending?rid_hash=eq.${encodeURIComponent(hash)}&select=*&limit=1`);
  const row: PendingRow | undefined = rows?.[0];
  if (!row) return null;
  if (row.consumed_at) return null;
  if (new Date(row.expires_at).getTime() <= Date.now()) return null;
  return row;
}

export async function attachSubject(rid: string, subject: string): Promise<void> {
  const hash = await sha256(rid);
  await pg(`oauth_pending?rid_hash=eq.${encodeURIComponent(hash)}`, {
    method: "PATCH",
    body: JSON.stringify({ subject }),
  });
}

export async function consumePending(rid: string): Promise<void> {
  const hash = await sha256(rid);
  await pg(`oauth_pending?rid_hash=eq.${encodeURIComponent(hash)}`, {
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
  const row = await findAnyToken(token, kind);
  if (!row) return null;
  if (row.revoked_at) return null;
  if (new Date(row.expires_at).getTime() <= Date.now()) return null;
  return row;
}

/**
 * The same lookup, revoked rows included. Used in exactly one place: telling a
 * refresh token that never existed apart from one that has already been spent.
 * The first is noise; the second means two parties hold the same token, and
 * only one of them should.
 */
export async function findAnyToken(token: string, kind: "access" | "refresh"): Promise<TokenRow | null> {
  const hash = await sha256(token);
  const rows = await pg(
    `oauth_tokens?token_hash=eq.${encodeURIComponent(hash)}&kind=eq.${kind}&select=*&limit=1`,
  );
  return rows?.[0] ?? null;
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

/**
 * Every live token belonging to one person. A replayed authorization code is
 * the one case where we do not know which grant family the attacker holds, so
 * the only safe answer is all of them.
 */
export async function revokeAllForSubject(subject: string): Promise<void> {
  await pg(`oauth_tokens?subject=eq.${encodeURIComponent(subject)}&revoked_at=is.null`, {
    method: "PATCH",
    body: JSON.stringify({ revoked_at: new Date().toISOString() }),
  });
}
