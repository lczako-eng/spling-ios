// ============================================================================
// Square rail. Menus are READ from the catalog — never scraped, never cached
// beyond MENU_TTL_MS, because a stale price is a wrong order.
//
// PCI scope stays at zero: we create an order and a hosted payment link. No
// card data touches this server, ever.
// ============================================================================

import type { CatalogItem, CatalogModifierList, Menu, ResolvedLineItem } from "./compose.ts";

/** Env read without binding this module to a global at load time, so the pure
 *  helpers below stay importable by the test runner. */
// deno-lint-ignore no-explicit-any
const env = (k: string): string => (globalThis as any).Deno?.env?.get(k) ?? "";

const SQUARE_ENV = env("SQUARE_ENV") || "sandbox";
const SQUARE_BASE = SQUARE_ENV === "production"
  ? "https://connect.squareup.com"
  : "https://connect.squareupsandbox.com";
const SQUARE_TOKEN = env("SQUARE_ACCESS_TOKEN");
const SQUARE_VERSION = "2026-07-16"; // pinned; update deliberately

export const MENU_TTL_MS = 15 * 60 * 1000;

export class SquareError extends Error {
  status: number;
  detail: unknown;
  // Written without TS parameter properties on purpose: that syntax cannot be
  // type-stripped, and these modules are exercised by the test runner directly.
  constructor(status: number, detail: unknown, message: string) {
    super(message);
    this.name = "SquareError";
    this.status = status;
    this.detail = detail;
  }
}

export async function square(path: string, init: RequestInit = {}): Promise<any> {
  const res = await fetch(`${SQUARE_BASE}${path}`, {
    ...init,
    headers: {
      "Authorization": `Bearer ${SQUARE_TOKEN}`,
      "Square-Version": SQUARE_VERSION,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const detail = body?.errors ?? body;
    throw new SquareError(res.status, detail, `Square ${path} failed (${res.status})`);
  }
  return body;
}

// ---------------------------------------------------------------------------
// catalog → Menu
// ---------------------------------------------------------------------------

type CachedMenu = { at: number; menu: Menu };
const menuCache = new Map<string, CachedMenu>();

export function clearMenuCache() { menuCache.clear(); }

/** Pure so it can be tested without the network. */
export function buildMenu(locationId: string, objects: any[]): Menu {
  const categories = new Map<string, string>();
  for (const o of objects.filter((o) => o.type === "CATEGORY")) {
    categories.set(o.id, o.category_data?.name ?? "Other");
  }

  const modifierLists = new Map<string, CatalogModifierList>();
  for (const o of objects.filter((o) => o.type === "MODIFIER_LIST")) {
    modifierLists.set(o.id, {
      id: o.id,
      name: o.modifier_list_data?.name ?? "Options",
      modifiers: (o.modifier_list_data?.modifiers ?? []).map((m: any) => ({
        id: m.id,
        name: m.modifier_data?.name ?? "",
        price_cents: Number(m.modifier_data?.price_money?.amount ?? 0),
      })),
    });
  }

  const items: CatalogItem[] = objects
    .filter((o) => o.type === "ITEM")
    .map((o: any) => {
      const d = o.item_data ?? {};
      return {
        id: o.id,
        name: d.name ?? "",
        description: d.description ?? null,
        category: categories.get(d.category_id) ?? "Menu",
        allergens: (d.food_and_beverage_details?.dietary_preferences ?? [])
          .map((p: any) => String(p?.standard_name ?? p?.custom_name ?? "").toLowerCase())
          .filter(Boolean),
        variations: (d.variations ?? []).map((v: any) => ({
          id: v.id,
          name: v.item_variation_data?.name ?? "Regular",
          price_cents: Number(v.item_variation_data?.price_money?.amount ?? 0),
          currency: v.item_variation_data?.price_money?.currency ?? "CAD",
        })),
        modifier_lists: (d.modifier_list_info ?? [])
          .map((mi: any) => modifierLists.get(mi.modifier_list_id))
          .filter(Boolean) as CatalogModifierList[],
      };
    })
    // An item with no price cannot be ordered, so it does not belong on a menu.
    .filter((i) => i.variations.length > 0);

  return { location_id: locationId, fetched_at: new Date().toISOString(), items };
}

export async function fetchMenu(locationId: string, force = false): Promise<Menu> {
  const cached = menuCache.get(locationId);
  if (!force && cached && Date.now() - cached.at < MENU_TTL_MS) return cached.menu;

  const objects: any[] = [];
  let cursor: string | undefined;
  do {
    const qs = new URLSearchParams({ types: "ITEM,MODIFIER_LIST,CATEGORY" });
    if (cursor) qs.set("cursor", cursor);
    const page = await square(`/v2/catalog/list?${qs}`);
    objects.push(...(page.objects ?? []));
    cursor = page.cursor;
  } while (cursor);

  const menu = buildMenu(locationId, objects);
  menuCache.set(locationId, { at: Date.now(), menu });
  return menu;
}

export async function defaultLocationId(): Promise<string> {
  const locs = await square("/v2/locations");
  const id = locs.locations?.find((l: any) => l.status === "ACTIVE")?.id ?? locs.locations?.[0]?.id;
  if (!id) throw new Error("No Square location is available on this account.");
  return id;
}

// ---------------------------------------------------------------------------
// orders + payment links
// ---------------------------------------------------------------------------

export function toSquareLineItems(items: ResolvedLineItem[]) {
  return items.map((l) => ({
    quantity: String(l.qty),
    catalog_object_id: l.catalog_object_id,
    modifiers: l.modifiers.map((m) => ({ catalog_object_id: m.catalog_object_id })),
  }));
}

export async function createOrder(
  locationId: string,
  items: ResolvedLineItem[],
  idempotencyKey: string,
  referenceId: string,
): Promise<{ id: string; total_cents: number; currency: string }> {
  const body = {
    idempotency_key: idempotencyKey,
    order: {
      location_id: locationId,
      reference_id: referenceId,          // the pickup code — never anything about the person
      line_items: toSquareLineItems(items),
      state: "OPEN",
    },
  };
  const res = await square("/v2/orders", { method: "POST", body: JSON.stringify(body) });
  return {
    id: res.order?.id,
    total_cents: Number(res.order?.total_money?.amount ?? 0),
    currency: res.order?.total_money?.currency ?? "CAD",
  };
}

export async function createPaymentLink(
  orderId: string,
  idempotencyKey: string,
  note: string,
): Promise<{ url: string; id: string }> {
  const res = await square("/v2/online-checkout/payment-links", {
    method: "POST",
    body: JSON.stringify({
      idempotency_key: idempotencyKey,
      order_id: orderId,
      checkout_options: { ask_for_shipping_address: false, note },
    }),
  });
  return { url: res.payment_link?.url ?? "", id: res.payment_link?.id ?? "" };
}

export async function getOrder(orderId: string): Promise<any> {
  const res = await square(`/v2/orders/${orderId}`);
  return res.order;
}

/** Square order state → our status vocabulary (see 001_init.sql). */
export function mapSquareState(state: string | undefined, tenders: unknown[] | undefined): string {
  if (state === "CANCELED") return "cancelled";
  if (state === "COMPLETED") return "picked_up";
  if (tenders && tenders.length > 0) return "paid";
  return "payment_pending";
}
