// ============================================================================
// Tests for the composition engine.
//
// Run:  node --experimental-strip-types compose_test.ts
//
// These are the tests that matter. Everything else in this repo can be redone;
// an order that reaches a merchant wrong is the failure the product exists to
// prevent, so the validator is tested against the ways it could plausibly lie.
// ============================================================================

import {
  compose, normalize, pickupCode, renderLines,
  type CatalogItem, type Menu, type DietaryConstraint,
} from "./compose.ts";

// ---------------------------------------------------------------------------
// tiny test harness
// ---------------------------------------------------------------------------
let passed = 0;
const failures: string[] = [];

function test(name: string, fn: () => void) {
  try { fn(); passed++; }
  catch (e) { failures.push(`${name}\n    ${(e as Error).message}`); }
}
function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(msg);
}
function eq(actual: unknown, expected: unknown, msg = "") {
  const a = JSON.stringify(actual), b = JSON.stringify(expected);
  if (a !== b) throw new Error(`${msg}\n    expected: ${b}\n    actual:   ${a}`);
}

// ---------------------------------------------------------------------------
// fixture: a small, realistic café catalog
// ---------------------------------------------------------------------------
const MILK = {
  id: "ML_MILK", name: "Milk",
  modifiers: [
    { id: "MOD_OAT", name: "Oat Milk", price_cents: 75 },
    { id: "MOD_SOY", name: "Soy Milk", price_cents: 60 },
    { id: "MOD_WHOLE", name: "Whole Milk", price_cents: 0 },
  ],
};
const SHOTS = {
  id: "ML_SHOTS", name: "Espresso",
  modifiers: [
    { id: "MOD_DECAF", name: "Decaf", price_cents: 0 },
    { id: "MOD_EXTRA", name: "Extra Shot", price_cents: 90 },
  ],
};
const BREAD = {
  id: "ML_BREAD", name: "Bread",
  modifiers: [
    { id: "MOD_SOURDOUGH", name: "Sourdough", price_cents: 0 },
    { id: "MOD_RYE", name: "Rye", price_cents: 0 },
  ],
};

const ITEMS: CatalogItem[] = [
  {
    id: "ITEM_LATTE", name: "Latte", category: "Coffee",
    variations: [
      { id: "VAR_LATTE_S", name: "Small", price_cents: 450, currency: "CAD" },
      { id: "VAR_LATTE_L", name: "Large", price_cents: 550, currency: "CAD" },
    ],
    modifier_lists: [MILK, SHOTS],
  },
  {
    id: "ITEM_FLAT", name: "Flat White", category: "Coffee",
    variations: [{ id: "VAR_FLAT", name: "Regular", price_cents: 500, currency: "CAD" }],
    modifier_lists: [MILK],
  },
  {
    id: "ITEM_PBJ", name: "Peanut Butter Sandwich", category: "Food",
    description: "House peanut butter and raspberry jam",
    allergens: ["peanut"],
    variations: [{ id: "VAR_PBJ", name: "Regular", price_cents: 850, currency: "CAD" }],
    modifier_lists: [BREAD],
  },
  {
    id: "ITEM_TURKEY", name: "Turkey Sandwich", category: "Food",
    variations: [{ id: "VAR_TURKEY", name: "Regular", price_cents: 990, currency: "CAD" }],
    modifier_lists: [BREAD],
  },
];

const MENU: Menu = { location_id: "L1", fetched_at: new Date(0).toISOString(), items: ITEMS };

// ---------------------------------------------------------------------------
// the happy path
// ---------------------------------------------------------------------------
test("resolves item + size + modifier and prices it in integer cents", () => {
  const r = compose({ menu: MENU, requested: [{ name_or_id: "Latte", variation: "Large", modifiers: ["Oat Milk"], qty: 1 }] });
  assert(r.ok, "should compose");
  eq(r.line_items.length, 1, "one line");
  const l = r.line_items[0];
  eq(l.catalog_object_id, "VAR_LATTE_L", "resolves the LARGE variation id");
  eq(l.modifiers[0].catalog_object_id, "MOD_OAT", "resolves the modifier id");
  eq(l.line_cents, 550 + 75, "550 base + 75 oat");
  eq(r.total_cents, 625, "total");
});

test("multiplies by quantity without floats", () => {
  const r = compose({ menu: MENU, requested: [{ name_or_id: "Latte", variation: "Small", qty: 3 }] });
  eq(r.total_cents, 1350, "3 × 450");
  assert(Number.isInteger(r.total_cents), "integer cents");
});

test("matches across diacritics — the cross-language case", () => {
  // 'lattét' is the Hungarian accusative; it must still resolve to Latte.
  const r = compose({ menu: MENU, requested: [{ name_or_id: "lattét", variation: "Large", modifiers: ["oat milk"] }] });
  assert(r.ok, `should resolve accented input: ${JSON.stringify(r.rejections)}`);
  eq(r.line_items[0].catalog_object_id, "VAR_LATTE_L", "same catalog id");
});

test("accepts a raw catalog id", () => {
  const r = compose({ menu: MENU, requested: [{ name_or_id: "ITEM_FLAT" }] });
  assert(r.ok, "id lookup");
  eq(r.line_items[0].catalog_object_id, "VAR_FLAT", "single variation auto-selected");
});

// ---------------------------------------------------------------------------
// rejection — the part that protects the merchant
// ---------------------------------------------------------------------------
test("rejects an item that is not on the menu", () => {
  const r = compose({ menu: MENU, requested: [{ name_or_id: "Unicorn Burger" }] });
  assert(!r.ok, "must not compose");
  eq(r.rejections[0].code, "item_not_found", "code");
  eq(r.line_items.length, 0, "nothing accepted");
});

test("refuses to guess between two plausible items", () => {
  const r = compose({ menu: MENU, requested: [{ name_or_id: "Sandwich" }] });
  assert(!r.ok, "must not compose");
  eq(r.rejections[0].code, "item_ambiguous", "ambiguity is a rejection, not a coin flip");
  assert((r.rejections[0].candidates ?? []).length === 2, "offers both candidates");
});

test("asks for a size rather than picking one", () => {
  const r = compose({ menu: MENU, requested: [{ name_or_id: "Latte" }] });
  assert(!r.ok, "must not compose");
  eq(r.rejections[0].code, "variation_ambiguous", "never silently picks a size");
});

test("rejects a modifier that is real but belongs to another item", () => {
  // Sourdough exists on the catalog — but not for a Latte.
  const r = compose({ menu: MENU, requested: [{ name_or_id: "Latte", variation: "Large", modifiers: ["Sourdough"] }] });
  assert(!r.ok, "must not compose");
  eq(r.rejections[0].code, "modifier_not_valid_for_item", "cross-item modifiers are invalid");
});

test("rejects non-integer, zero, negative and oversized quantities", () => {
  for (const qty of [0, -2, 2.5, 9999]) {
    const r = compose({ menu: MENU, requested: [{ name_or_id: "Flat White", qty }] });
    assert(!r.ok, `qty ${qty} must be rejected`);
    eq(r.rejections[0].code, "invalid_quantity", `qty ${qty}`);
  }
});

test("one bad line rejects the whole order — a partial order is a wrong order", () => {
  const r = compose({
    menu: MENU,
    requested: [
      { name_or_id: "Latte", variation: "Large", modifiers: ["Oat Milk"] },
      { name_or_id: "Unicorn Burger" },
    ],
  });
  assert(!r.ok, "must not compose");
  eq(r.line_items.length, 1, "the good line still resolved…");
  assert(r.rejections.length === 1, "…but the order is not ok");
});

// ---------------------------------------------------------------------------
// dietary enforcement — the safety-critical path
// ---------------------------------------------------------------------------
const ANAPHYLAXIS: DietaryConstraint[] = [{ kind: "allergen", value: "peanut", severity: "anaphylaxis" }];

test("anaphylaxis allergen hard-blocks the item", () => {
  const r = compose({ menu: MENU, requested: [{ name_or_id: "Peanut Butter Sandwich" }], dietary: ANAPHYLAXIS });
  assert(!r.ok, "must not compose");
  eq(r.rejections[0].code, "blocked_allergen", "code");
  eq(r.rejections[0].overridable, false, "never overridable");
});

test("anaphylaxis block cannot be overridden, even explicitly", () => {
  const r = compose({
    menu: MENU,
    requested: [{ name_or_id: "Peanut Butter Sandwich" }],
    dietary: ANAPHYLAXIS,
    overrides: ["peanut"],   // caller insists
  });
  assert(!r.ok, "override must be ignored for anaphylaxis");
  eq(r.rejections[0].code, "blocked_allergen", "still blocked");
});

test("allergen is caught via the item description, not just a tag", () => {
  const withoutTag: Menu = {
    ...MENU,
    items: MENU.items.map((i) => (i.id === "ITEM_PBJ" ? { ...i, allergens: [] } : i)),
  };
  const r = compose({ menu: withoutTag, requested: [{ name_or_id: "Peanut Butter Sandwich" }], dietary: ANAPHYLAXIS });
  assert(!r.ok, "description mentions peanut butter — must still block");
  eq(r.rejections[0].code, "blocked_allergen", "code");
});

test("strict constraint blocks, but an explicit override lets it through", () => {
  const strict: DietaryConstraint[] = [{ kind: "diet", value: "turkey", severity: "strict" }];
  const blocked = compose({ menu: MENU, requested: [{ name_or_id: "Turkey Sandwich" }], dietary: strict });
  assert(!blocked.ok, "blocked by default");
  eq(blocked.rejections[0].overridable, true, "flagged overridable");

  const allowed = compose({ menu: MENU, requested: [{ name_or_id: "Turkey Sandwich" }], dietary: strict, overrides: ["turkey"] });
  assert(allowed.ok, "explicit override permits it");
});

test("preference warns but does not block", () => {
  const pref: DietaryConstraint[] = [{ kind: "dislike", value: "soy", severity: "preference" }];
  const r = compose({ menu: MENU, requested: [{ name_or_id: "Flat White", modifiers: ["Soy Milk"] }], dietary: pref });
  assert(r.ok, "preference must not block");
  eq(r.warnings.length, 1, "but it warns");
});

test("an allergen introduced by a MODIFIER is caught too", () => {
  const soyAllergy: DietaryConstraint[] = [{ kind: "allergen", value: "soy", severity: "anaphylaxis" }];
  const r = compose({ menu: MENU, requested: [{ name_or_id: "Flat White", modifiers: ["Soy Milk"] }], dietary: soyAllergy });
  assert(!r.ok, "the modifier carries the allergen");
  eq(r.rejections[0].code, "blocked_allergen", "code");
});

// ---------------------------------------------------------------------------
// audit trail + helpers
// ---------------------------------------------------------------------------
test("every decision is logged for order_events", () => {
  const r = compose({ menu: MENU, requested: [{ name_or_id: "Latte", variation: "Large" }, { name_or_id: "Nope" }] });
  const kinds = r.events.map((e) => e.event);
  assert(kinds.includes("item_validated"), "logs accepts");
  assert(kinds.includes("item_rejected"), "logs rejects");
  assert(kinds.includes("composition_failed"), "logs the outcome");
});

test("renderLines produces merchant-language receipt lines", () => {
  const r = compose({ menu: MENU, requested: [{ name_or_id: "Latte", variation: "Large", modifiers: ["Oat Milk"], qty: 2 }] });
  eq(renderLines(r.line_items), ["2× Latte Large · Oat Milk"], "receipt line");
});

test("pickup codes avoid ambiguous characters", () => {
  let seq = 0;
  const code = pickupCode(() => { const v = (seq * 0.037) % 1; seq++; return v; });
  assert(/^SPL-[A-Z2-9]{4}$/.test(code), `shape: ${code}`);
  for (const bad of ["O", "0", "I", "1", "S", "5"]) {
    assert(!code.slice(4).includes(bad), `must not contain ${bad}: ${code}`);
  }
});

test("normalize strips diacritics and punctuation", () => {
  eq(normalize("  Lattét,  Nagy! "), "lattet nagy", "normalized");
});

// ---------------------------------------------------------------------------
// report
// ---------------------------------------------------------------------------
console.log(`\ncompose engine: ${passed} passed, ${failures.length} failed\n`);
if (failures.length) {
  for (const f of failures) console.error("  ✗ " + f + "\n");
  process.exit(1);
}
console.log("  ✓ all composition guarantees hold\n");
