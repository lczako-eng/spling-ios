// ============================================================================
// THE COMPOSITION ENGINE — the moat, and the only part that must never be wrong.
//
// Contract (CLAUDE.md): the LLM maps intent to CANDIDATE items. This file is the
// deterministic half. It validates every candidate against the live Square
// catalog and REJECTS anything that does not resolve exactly. Nothing this
// function has not personally verified can reach a merchant.
//
// Rules, in order of authority:
//   1. An item must resolve to exactly one catalog variation. Ambiguity is a
//      rejection, never a guess — two plausible matches means we ask, because
//      guessing is precisely the failure mode we exist to remove.
//   2. A modifier must belong to one of the item's own modifier lists. A valid
//      modifier from the wrong item is still invalid.
//   3. Quantities are integers, 1..MAX_QTY.
//   4. Dietary constraints are enforced HERE, before an order can exist:
//        anaphylaxis -> hard block, never overridable
//        strict      -> blocked unless the caller passes an explicit override
//        preference  -> allowed, warned
//   5. All money is integer cents. Never floats.
//
// This module is pure: no network, no database, no Deno APIs. That is what
// makes it testable, and it is tested in compose_test.ts.
// ============================================================================

export const MAX_QTY = 50;

export type Severity = "preference" | "strict" | "anaphylaxis";

export interface DietaryConstraint {
  kind: "allergen" | "diet" | "dislike";
  value: string;
  severity: Severity;
}

export interface CatalogModifier {
  id: string;
  name: string;
  price_cents: number;
}

export interface CatalogModifierList {
  id: string;
  name: string;
  modifiers: CatalogModifier[];
}

export interface CatalogVariation {
  id: string;
  name: string;
  price_cents: number;
  currency: string;
}

export interface CatalogItem {
  id: string;
  name: string;
  description?: string | null;
  category?: string;
  variations: CatalogVariation[];
  modifier_lists: CatalogModifierList[];
  /** Allergen tags, if the merchant publishes them. Absence is not safety. */
  allergens?: string[];
}

export interface Menu {
  location_id: string;
  fetched_at: string;
  items: CatalogItem[];
}

/** What the assistant proposes. Free text — none of it is trusted. */
export interface RequestedItem {
  name_or_id: string;
  qty?: number;
  variation?: string;
  modifiers?: string[];
}

export interface ResolvedModifier {
  catalog_object_id: string;
  name: string;
  price_cents: number;
}

export interface ResolvedLineItem {
  catalog_object_id: string;
  item_id: string;
  name: string;
  variation_name: string;
  qty: number;
  modifiers: ResolvedModifier[];
  base_cents: number;
  line_cents: number;
}

export type RejectionCode =
  | "item_not_found"
  | "item_ambiguous"
  | "variation_not_found"
  | "variation_ambiguous"
  | "modifier_not_found"
  | "modifier_not_valid_for_item"
  | "modifier_ambiguous"
  | "invalid_quantity"
  | "blocked_allergen"
  | "blocked_dietary";

export interface Rejection {
  requested: string;
  code: RejectionCode;
  reason: string;
  /** Only ever set for non-anaphylaxis blocks. */
  overridable?: boolean;
  candidates?: string[];
}

export interface Warning {
  requested: string;
  code: "dietary_preference";
  reason: string;
}

export interface CompositionResult {
  ok: boolean;
  line_items: ResolvedLineItem[];
  rejections: Rejection[];
  warnings: Warning[];
  total_cents: number;
  currency: string;
  /** Every accept and reject, for order_events. The audit trail is not optional. */
  events: Array<{ event: string; detail: Record<string, unknown> }>;
}

// ---------------------------------------------------------------------------
// Matching. Deliberately conservative: exact, then unique prefix/substring.
// No fuzzy distance scoring — "close enough" is how you get the wrong coffee.
// ---------------------------------------------------------------------------

export function normalize(s: string): string {
  return s
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")   // strip diacritics so "lattét" matches "latte"
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

interface Match<T> { exact: T[]; partial: T[]; }

function matchByName<T>(needle: string, pool: T[], nameOf: (t: T) => string, idOf: (t: T) => string): Match<T> {
  const n = normalize(needle);
  const exact: T[] = [];
  const partial: T[] = [];
  for (const candidate of pool) {
    if (idOf(candidate) === needle) return { exact: [candidate], partial: [] }; // catalog ID wins outright
    const cn = normalize(nameOf(candidate));
    if (cn === n) exact.push(candidate);
    else if (n.length >= 3 && (cn.includes(n) || n.includes(cn))) partial.push(candidate);
  }
  return { exact, partial };
}

/** Exactly one match, or nothing. Ambiguity is never resolved silently. */
function resolveUnique<T>(m: Match<T>): { hit?: T; ambiguous: T[] } {
  if (m.exact.length === 1) return { hit: m.exact[0], ambiguous: [] };
  if (m.exact.length > 1) return { ambiguous: m.exact };
  if (m.partial.length === 1) return { hit: m.partial[0], ambiguous: [] };
  if (m.partial.length > 1) return { ambiguous: m.partial };
  return { ambiguous: [] };
}

// ---------------------------------------------------------------------------
// Dietary enforcement
// ---------------------------------------------------------------------------

function textOf(item: CatalogItem, variation: CatalogVariation, mods: ResolvedModifier[]): string {
  return normalize(
    [item.name, item.description ?? "", (item.allergens ?? []).join(" "), variation.name, mods.map((m) => m.name).join(" ")]
      .join(" ")
  );
}

/**
 * A constraint hits when its value appears in the item's own words. This is
 * intentionally blunt: a false positive costs one clarifying question, a false
 * negative can cost someone an ambulance. We fail toward blocking.
 */
function constraintHits(c: DietaryConstraint, haystack: string): boolean {
  const v = normalize(c.value);
  if (!v) return false;
  return haystack.split(" ").includes(v) || haystack.includes(v);
}

// ---------------------------------------------------------------------------
// compose
// ---------------------------------------------------------------------------

export interface ComposeOptions {
  menu: Menu;
  requested: RequestedItem[];
  dietary?: DietaryConstraint[];
  /** Values the user has explicitly overridden this order. Never applies to anaphylaxis. */
  overrides?: string[];
}

export function compose(opts: ComposeOptions): CompositionResult {
  const { menu, requested } = opts;
  const dietary = opts.dietary ?? [];
  const overrides = new Set((opts.overrides ?? []).map(normalize));

  const line_items: ResolvedLineItem[] = [];
  const rejections: Rejection[] = [];
  const warnings: Warning[] = [];
  const events: CompositionResult["events"] = [];

  let total = 0;
  let currency = "CAD";

  for (const req of requested) {
    const label = req.name_or_id;

    // ---- quantity ----
    const qty = req.qty === undefined ? 1 : req.qty;
    if (!Number.isInteger(qty) || qty < 1 || qty > MAX_QTY) {
      const r: Rejection = {
        requested: label,
        code: "invalid_quantity",
        reason: `Quantity must be a whole number between 1 and ${MAX_QTY}. Got: ${String(req.qty)}.`,
      };
      rejections.push(r);
      events.push({ event: "item_rejected", detail: { ...r } });
      continue;
    }

    // ---- item ----
    const itemMatch = resolveUnique(matchByName(label, menu.items, (i) => i.name, (i) => i.id));
    if (!itemMatch.hit) {
      const r: Rejection = itemMatch.ambiguous.length
        ? {
            requested: label,
            code: "item_ambiguous",
            reason: `"${label}" matches more than one item on this menu. Ask which one.`,
            candidates: itemMatch.ambiguous.map((i) => i.name),
          }
        : {
            requested: label,
            code: "item_not_found",
            reason: `"${label}" is not on this menu.`,
          };
      rejections.push(r);
      events.push({ event: "item_rejected", detail: { ...r } });
      continue;
    }
    const item = itemMatch.hit;

    // ---- variation (size) ----
    if (!item.variations.length) {
      const r: Rejection = {
        requested: label,
        code: "variation_not_found",
        reason: `"${item.name}" has no purchasable variation in the catalog.`,
      };
      rejections.push(r);
      events.push({ event: "item_rejected", detail: { ...r } });
      continue;
    }

    let variation: CatalogVariation;
    if (req.variation) {
      const vm = resolveUnique(matchByName(req.variation, item.variations, (v) => v.name, (v) => v.id));
      if (!vm.hit) {
        const r: Rejection = {
          requested: `${label} (${req.variation})`,
          code: vm.ambiguous.length ? "variation_ambiguous" : "variation_not_found",
          reason: vm.ambiguous.length
            ? `"${req.variation}" matches more than one size of ${item.name}.`
            : `${item.name} has no "${req.variation}" option.`,
          candidates: item.variations.map((v) => v.name),
        };
        rejections.push(r);
        events.push({ event: "item_rejected", detail: { ...r } });
        continue;
      }
      variation = vm.hit;
    } else if (item.variations.length === 1) {
      variation = item.variations[0];
    } else {
      const r: Rejection = {
        requested: label,
        code: "variation_ambiguous",
        reason: `${item.name} comes in more than one size. Ask which.`,
        candidates: item.variations.map((v) => v.name),
      };
      rejections.push(r);
      events.push({ event: "item_rejected", detail: { ...r } });
      continue;
    }

    // ---- modifiers ----
    const validMods: CatalogModifier[] = item.modifier_lists.flatMap((l) => l.modifiers);
    const resolvedMods: ResolvedModifier[] = [];
    let modFailed: Rejection | null = null;

    for (const wanted of req.modifiers ?? []) {
      const mm = resolveUnique(matchByName(wanted, validMods, (m) => m.name, (m) => m.id));
      if (!mm.hit) {
        modFailed = {
          requested: `${label} + ${wanted}`,
          code: mm.ambiguous.length ? "modifier_ambiguous" : "modifier_not_valid_for_item",
          reason: mm.ambiguous.length
            ? `"${wanted}" matches more than one option for ${item.name}.`
            : `"${wanted}" is not an available option for ${item.name}.`,
          candidates: validMods.map((m) => m.name),
        };
        break;
      }
      if (resolvedMods.some((m) => m.catalog_object_id === mm.hit!.id)) continue; // de-duplicate
      resolvedMods.push({ catalog_object_id: mm.hit.id, name: mm.hit.name, price_cents: mm.hit.price_cents });
    }

    if (modFailed) {
      rejections.push(modFailed);
      events.push({ event: "item_rejected", detail: { ...modFailed } });
      continue;
    }

    // ---- dietary enforcement, before the line exists ----
    const haystack = textOf(item, variation, resolvedMods);
    let blocked: Rejection | null = null;
    for (const c of dietary) {
      if (!constraintHits(c, haystack)) continue;

      if (c.severity === "anaphylaxis") {
        blocked = {
          requested: label,
          code: "blocked_allergen",
          reason: `${item.name} matches a recorded anaphylaxis allergen (${c.value}). This item cannot be ordered, and this block cannot be overridden here.`,
          overridable: false,
        };
        break;
      }
      if (c.severity === "strict") {
        if (overrides.has(normalize(c.value))) continue;
        blocked = {
          requested: label,
          code: "blocked_dietary",
          reason: `${item.name} conflicts with a strict dietary constraint (${c.value}). Confirm explicitly to override.`,
          overridable: true,
        };
        break;
      }
      warnings.push({
        requested: label,
        code: "dietary_preference",
        reason: `${item.name} matches something you usually avoid (${c.value}).`,
      });
    }

    if (blocked) {
      rejections.push(blocked);
      events.push({ event: "item_rejected", detail: { ...blocked } });
      continue;
    }

    // ---- accept ----
    const unit = variation.price_cents + resolvedMods.reduce((s, m) => s + m.price_cents, 0);
    const line_cents = unit * qty;
    currency = variation.currency || currency;

    const line: ResolvedLineItem = {
      catalog_object_id: variation.id,
      item_id: item.id,
      name: item.name,
      variation_name: variation.name,
      qty,
      modifiers: resolvedMods,
      base_cents: variation.price_cents,
      line_cents,
    };
    line_items.push(line);
    total += line_cents;
    events.push({ event: "item_validated", detail: { ...line } });
  }

  // An order is all-or-nothing: a partial order is a wrong order, and wrong
  // orders are the thing this product exists to eliminate.
  const ok = rejections.length === 0 && line_items.length > 0;
  events.push({
    event: ok ? "composed" : "composition_failed",
    detail: { accepted: line_items.length, rejected: rejections.length, total_cents: total },
  });

  return { ok, line_items, rejections, warnings, total_cents: total, currency, events };
}

/** Human-readable summary in the merchant's language — the receipt lines. */
export function renderLines(items: ResolvedLineItem[]): string[] {
  return items.map((l) => {
    const mods = l.modifiers.length ? ` · ${l.modifiers.map((m) => m.name).join(", ")}` : "";
    const size = l.variation_name && l.variation_name !== "Regular" ? ` ${l.variation_name}` : "";
    return `${l.qty}× ${l.name}${size}${mods}`;
  });
}

/** SPL-XXXX. Unambiguous alphabet: no O/0, no I/1, no S/5. */
export function pickupCode(rand: () => number = Math.random): string {
  const A = "ABCDEFGHJKLMNPQRTUVWXYZ2346789";
  let out = "";
  for (let i = 0; i < 4; i++) out += A[Math.floor(rand() * A.length)];
  return `SPL-${out}`;
}
