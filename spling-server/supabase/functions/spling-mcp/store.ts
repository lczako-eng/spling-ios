// ============================================================================
// Persistence. Supabase Postgres over PostgREST, service-role key, called only
// from this edge function — never from a client.
//
// PIPEDA rule (CLAUDE.md #3): communication_profile data is health-adjacent.
// It is never logged, never sent to Square, and never included in an error
// message. It informs composition, and nothing else. logEvent() below strips
// it defensively even if a caller passes it by accident.
// ============================================================================

import type { DietaryConstraint, ResolvedLineItem } from "./compose.ts";

// deno-lint-ignore no-explicit-any
const env = (k: string): string => (globalThis as any).Deno?.env?.get(k) ?? "";

const SUPABASE_URL = env("SUPABASE_URL");
const SERVICE_KEY = env("SUPABASE_SERVICE_ROLE_KEY");

async function pg(path: string, init: RequestInit = {}): Promise<any> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      "apikey": SERVICE_KEY,
      "Authorization": `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
      "Prefer": "return=representation",
      ...(init.headers ?? {}),
    },
  });
  const text = await res.text();
  const body = text ? JSON.parse(text) : null;
  if (!res.ok) throw new Error(`db ${path} ${res.status}: ${JSON.stringify(body)}`);
  return body;
}

// ---------------------------------------------------------------------------
// profiles
// ---------------------------------------------------------------------------

export interface Profile {
  id: string;
  display_name: string | null;
  compose_language: string;
  receipt_language: string;
}

export interface CommunicationProfile {
  communication_mode: string;
  notes_private: string | null;
  caretaker_staging_enabled: boolean;
}

/** One profile per authenticated identity; created on first contact. */
export async function ensureProfile(authUserId: string): Promise<Profile> {
  const found = await pg(`profiles?auth_user_id=eq.${authUserId}&select=id,display_name,compose_language,receipt_language&limit=1`);
  if (found?.length) return found[0];
  const made = await pg("profiles", { method: "POST", body: JSON.stringify({ auth_user_id: authUserId }) });
  return made[0];
}

export async function getCommunicationProfile(profileId: string): Promise<CommunicationProfile | null> {
  const rows = await pg(`communication_profiles?profile_id=eq.${profileId}&select=communication_mode,notes_private,caretaker_staging_enabled&limit=1`);
  return rows?.[0] ?? null;
}

export async function upsertCommunicationProfile(profileId: string, patch: Partial<CommunicationProfile>) {
  const body = { profile_id: profileId, ...patch, updated_at: new Date().toISOString() };
  return pg("communication_profiles?on_conflict=profile_id", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=representation" },
    body: JSON.stringify(body),
  });
}

export async function updateProfile(profileId: string, patch: Record<string, unknown>) {
  return pg(`profiles?id=eq.${profileId}`, { method: "PATCH", body: JSON.stringify(patch) });
}

export async function getDietary(profileId: string): Promise<DietaryConstraint[]> {
  const rows = await pg(`dietary_constraints?profile_id=eq.${profileId}&select=kind,value,severity`);
  return rows ?? [];
}

export async function addDietary(profileId: string, c: DietaryConstraint) {
  return pg("dietary_constraints", { method: "POST", body: JSON.stringify({ profile_id: profileId, ...c }) });
}

export async function removeDietary(profileId: string, value: string) {
  return pg(`dietary_constraints?profile_id=eq.${profileId}&value=eq.${encodeURIComponent(value)}`, { method: "DELETE" });
}

// ---------------------------------------------------------------------------
// merchants
// ---------------------------------------------------------------------------

export async function ensureMerchant(squareLocationId: string, displayName: string): Promise<string> {
  const found = await pg(`merchants?square_location_id=eq.${squareLocationId}&select=id&limit=1`);
  if (found?.length) return found[0].id;
  const made = await pg("merchants", {
    method: "POST",
    body: JSON.stringify({ square_location_id: squareLocationId, display_name: displayName }),
  });
  return made[0].id;
}

// ---------------------------------------------------------------------------
// orders
// ---------------------------------------------------------------------------

export interface OrderRow {
  id: string;
  status: string;
  line_items: ResolvedLineItem[];
  total_cents: number;
  currency: string;
  checkout_url: string | null;
  pickup_code: string | null;
  square_order_id: string | null;
  merchant_id: string;
  created_at: string;
}

export async function createDraftOrder(input: {
  profile_id: string;
  merchant_id: string;
  line_items: ResolvedLineItem[];
  total_cents: number;
  currency: string;
  user_utterance?: string | null;
  utterance_language?: string | null;
  staged_by?: string | null;
}): Promise<OrderRow> {
  const rows = await pg("orders", {
    method: "POST",
    body: JSON.stringify({ ...input, status: "composed" }),
  });
  return rows[0];
}

export async function patchOrder(orderId: string, patch: Record<string, unknown>): Promise<OrderRow> {
  const rows = await pg(`orders?id=eq.${orderId}`, { method: "PATCH", body: JSON.stringify(patch) });
  return rows[0];
}

export async function getOrderRow(orderId: string, profileId: string): Promise<OrderRow | null> {
  const rows = await pg(
    `orders?id=eq.${orderId}&or=(profile_id.eq.${profileId},staged_by.eq.${profileId})&select=*&limit=1`,
  );
  return rows?.[0] ?? null;
}

export async function listHistory(profileId: string, limit = 20): Promise<OrderRow[]> {
  return pg(`orders?profile_id=eq.${profileId}&order=created_at.desc&limit=${limit}&select=*`);
}

/** Health-adjacent fields are stripped before anything is written to the audit log. */
const NEVER_LOG = new Set(["notes_private", "communication_mode", "caretaker_staging_enabled", "email"]);

export async function logEvent(orderId: string, event: string, detail: Record<string, unknown>) {
  const safe: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(detail ?? {})) if (!NEVER_LOG.has(k)) safe[k] = v;
  try {
    await pg("order_events", { method: "POST", body: JSON.stringify({ order_id: orderId, event, detail: safe }) });
  } catch {
    // The audit trail must never take an order down with it.
  }
}

// ---------------------------------------------------------------------------
// accuracy ledger
// ---------------------------------------------------------------------------

export async function addCorrection(input: {
  order_id: string;
  profile_id: string;
  merchant_id: string;
  kind: string;
  item_name?: string | null;
  /** Set by ledger.ts so failures can be counted per catalogue entry (002). */
  line_item_index?: number | null;
  catalog_object_id?: string | null;
  modifier_name?: string | null;
  modifier_object_id?: string | null;
  ordered?: unknown;
  received?: unknown;
  note?: string | null;
}) {
  return pg("corrections", { method: "POST", body: JSON.stringify(input) });
}

export async function merchantAccuracy(merchantId?: string) {
  const q = merchantId ? `merchant_accuracy?merchant_id=eq.${merchantId}` : "merchant_accuracy";
  return pg(`${q}&select=*`.replace("?&", "?"));
}
