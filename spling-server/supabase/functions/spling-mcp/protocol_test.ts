// ============================================================================
// Protocol + wiring tests.
//
// Run:  node --experimental-strip-types protocol_test.ts
//
// compose_test.ts proves the validator is right. This file proves the pieces
// around it are wired right: the MCP envelope, the Square catalog mapping, the
// order/payment shapes, the status mapping, and the PAM export. No network and
// no database — the pure functions are exercised directly with fixtures.
// ============================================================================

import { buildMenu, mapSquareState, toSquareLineItems } from "./square.ts";
import { compose, renderLines, type Menu } from "./compose.ts";
import { toPam, PAM_SCHEMA } from "./pam.ts";

let passed = 0;
const failures: string[] = [];
function test(name: string, fn: () => void) {
  try { fn(); passed++; } catch (e) { failures.push(`${name}\n    ${(e as Error).message}`); }
}
function assert(c: unknown, m: string) { if (!c) throw new Error(m); }
function eq(a: unknown, b: unknown, m = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${m}\n    expected: ${y}\n    actual:   ${x}`);
}

// ---------------------------------------------------------------------------
// A realistic slice of a Square catalog/list response.
// ---------------------------------------------------------------------------
const SQUARE_OBJECTS = [
  { type: "CATEGORY", id: "CAT_COFFEE", category_data: { name: "Coffee" } },
  {
    type: "MODIFIER_LIST", id: "ML_MILK",
    modifier_list_data: {
      name: "Milk",
      modifiers: [
        { id: "MOD_OAT", modifier_data: { name: "Oat Milk", price_money: { amount: 75, currency: "CAD" } } },
        { id: "MOD_WHOLE", modifier_data: { name: "Whole Milk" } },
      ],
    },
  },
  {
    type: "ITEM", id: "ITEM_LATTE",
    item_data: {
      name: "Latte", category_id: "CAT_COFFEE", description: "Espresso and steamed milk",
      modifier_list_info: [{ modifier_list_id: "ML_MILK" }],
      variations: [
        { id: "VAR_S", item_variation_data: { name: "Small", price_money: { amount: 450, currency: "CAD" } } },
        { id: "VAR_L", item_variation_data: { name: "Large", price_money: { amount: 550, currency: "CAD" } } },
      ],
    },
  },
  {
    // No priced variation — must not appear on a menu, because it cannot be ordered.
    type: "ITEM", id: "ITEM_GHOST",
    item_data: { name: "Seasonal Special", variations: [] },
  },
];

// ---------------------------------------------------------------------------
// catalog mapping
// ---------------------------------------------------------------------------
test("buildMenu maps items, variations, modifiers and category", () => {
  const menu = buildMenu("L1", SQUARE_OBJECTS);
  eq(menu.offerings.length, 1, "unorderable item excluded");
  const latte = menu.offerings[0];
  eq(latte.name, "Latte", "name");
  eq(latte.category, "Coffee", "category resolved from CATEGORY object");
  eq(latte.variants.map((v) => v.id), ["VAR_S", "VAR_L"], "variants");
  eq(latte.variants[1].price_cents, 550, "integer cents");
  eq(latte.option_groups[0].options.map((m) => m.id), ["MOD_OAT", "MOD_WHOLE"], "options attached");
  eq(latte.option_groups[0].options[1].price_cents, 0, "missing price money is 0, not NaN");
});

test("buildMenu output feeds compose directly", () => {
  const menu = buildMenu("L1", SQUARE_OBJECTS);
  const r = compose({ menu, requested: [{ name_or_id: "Latte", variation: "Large", modifiers: ["Oat Milk"] }] });
  assert(r.ok, `should compose from a real catalog shape: ${JSON.stringify(r.rejections)}`);
  eq(r.total_cents, 625, "550 + 75");
});

// ---------------------------------------------------------------------------
// Square order payload
// ---------------------------------------------------------------------------
test("toSquareLineItems sends only catalog IDs — never names or free text", () => {
  const menu = buildMenu("L1", SQUARE_OBJECTS);
  const r = compose({ menu, requested: [{ name_or_id: "Latte", variation: "Large", modifiers: ["Oat Milk"], qty: 2 }] });
  const payload = toSquareLineItems(r.line_items);
  eq(payload, [{ quantity: "2", catalog_object_id: "VAR_L", modifiers: [{ catalog_object_id: "MOD_OAT" }] }], "payload");

  const asText = JSON.stringify(payload);
  for (const leak of ["Latte", "Oat Milk", "Large"]) {
    assert(!asText.includes(leak), `payload must not contain the human string "${leak}"`);
  }
});

test("quantity is sent as a string, as the Orders API requires", () => {
  const menu = buildMenu("L1", SQUARE_OBJECTS);
  const r = compose({ menu, requested: [{ name_or_id: "Latte", variation: "Small", qty: 3 }] });
  eq(typeof toSquareLineItems(r.line_items)[0].quantity, "string", "quantity type");
});

// ---------------------------------------------------------------------------
// status mapping
// ---------------------------------------------------------------------------
test("mapSquareState covers the states we act on", () => {
  eq(mapSquareState("OPEN", []), "payment_pending", "open, unpaid");
  eq(mapSquareState("OPEN", [{ id: "t1" }]), "paid", "a tender means paid");
  eq(mapSquareState("COMPLETED", [{ id: "t1" }]), "picked_up", "completed");
  eq(mapSquareState("CANCELED", []), "cancelled", "cancelled");
  eq(mapSquareState(undefined, undefined), "payment_pending", "unknown is never optimistic");
});

// ---------------------------------------------------------------------------
// receipt rendering
// ---------------------------------------------------------------------------
test("renderLines omits a meaningless 'Regular' size", () => {
  const menu: Menu = {
    provider: "test", location_id: "L1", kind: "menu", noun: "order", fetched_at: "",
    offerings: [{
      id: "I", name: "Flat White",
      variants: [{ id: "V", name: "Regular", price_cents: 500, currency: "CAD" }],
      option_groups: [],
    }],
  };
  const r = compose({ menu, requested: [{ name_or_id: "Flat White" }] });
  eq(renderLines(r.line_items), ["1× Flat White"], "no dangling 'Regular'");
});

// ---------------------------------------------------------------------------
// PAM export
// ---------------------------------------------------------------------------
test("PAM export carries language, allergens, accessibility and habits", () => {
  const pam = toPam({
    profile: { id: "p1", display_name: "Sam", compose_language: "hu", receipt_language: "hu" },
    communication: { communication_mode: "aac_user", notes_private: null, caretaker_staging_enabled: true },
    dietary: [{ kind: "allergen", value: "peanut", severity: "anaphylaxis" }],
    history: [
      { id: "o1", status: "picked_up", total_cents: 625, currency: "CAD", checkout_url: null, pickup_code: "SPL-AAAA",
        square_order_id: "s1", merchant_id: "m1", created_at: "",
        line_items: [{ catalog_object_id: "VAR_L", item_id: "I", name: "Latte", variation_name: "Large", qty: 1,
                       modifiers: [{ catalog_object_id: "MOD_OAT", name: "Oat Milk", price_cents: 75 }],
                       base_cents: 550, line_cents: 625 }] },
    ],
    exportedAt: "1970-01-01T00:00:00.000Z",
  });

  eq(pam.schema, PAM_SCHEMA, "conforms to the published schema name");
  const keys = pam.memories.map((m) => m.key);
  assert(keys.includes("language.compose"), "language exported");
  assert(keys.includes("communication.mode"), "accessibility exported — it is the user's to take");
  assert(keys.includes("dietary.allergen.peanut"), "allergen exported");
  assert(keys.includes("ordering.frequent_item"), "habits derived");

  const habit = pam.memories.find((m) => m.key === "ordering.frequent_item")!;
  assert(habit.confidence < 1, "derived memories carry lower confidence than declarations");
  eq((habit.value as any).item, "Latte Large · Oat Milk", "habit label");
});

test("PAM export of an empty profile is still valid", () => {
  const pam = toPam({
    profile: { id: "p2", display_name: null, compose_language: "en", receipt_language: "en" },
    communication: null, dietary: [], history: [],
  });
  eq(pam.schema, PAM_SCHEMA, "schema");
  eq(pam.memories.length, 2, "just the two language declarations");
});

// ---------------------------------------------------------------------------
// tool surface contract
// ---------------------------------------------------------------------------
test("index.ts declares exactly the nine specified tools", async () => {
  const src = await (await import("node:fs/promises")).readFile(new URL("./index.ts", import.meta.url), "utf8");
  const declared = [...src.matchAll(/^\s{4}name: "([a-z_]+)",$/gm)].map((m) => m[1]);
  eq(declared.sort(), [
    "compose_order", "export_profile", "get_catalog", "get_history", "get_order_status",
    "get_profile", "place_order", "submit_correction", "update_profile",
  ], "tool surface");
});

// ---------------------------------------------------------------------------
// cross-rail contract
//
// The iOS app and this connector both write corrections into one accuracy
// ledger. A value that exists on only one side produces rows the other cannot
// read — and an unreadable correction is an unattributable one, which is the
// failure the ledger exists to prevent. Swift tests need a Mac; this one runs
// everywhere, so this is the guard that actually fires.
// ---------------------------------------------------------------------------
test("the app and the connector agree on what can go wrong", async () => {
  const fs = await import("node:fs/promises");
  const here = new URL("./index.ts", import.meta.url);
  const swift = new URL("../../../../spLing/Models.swift", here);

  const server = [...(await fs.readFile(here, "utf8"))
    .matchAll(/enum: \["missing_item"[^\]]*\]/g)]
    .map((m) => [...m[0].matchAll(/"([a-z_]+)"/g)].map((x) => x[1]))[0];
  assert(server?.length, "could not find the submit_correction kind enum in index.ts");

  const src = await fs.readFile(swift, "utf8");
  const block = src.match(/enum CorrectionKind[\s\S]*?\n\}/)?.[0] ?? "";
  const app = [...block.matchAll(/case\s+\w+\s*=\s*"([a-z_]+)"/g)].map((m) => m[1]);
  assert(app.length, "could not find CorrectionKind in Models.swift");

  eq(app.slice().sort(), server.slice().sort(), "correction kinds have drifted between the two rails");
});

test("no secret is hard-coded anywhere in the function", async () => {
  const fs = await import("node:fs/promises");
  for (const f of ["index.ts", "square.ts", "store.ts", "compose.ts", "pam.ts", "ledger.ts", "catalogue.ts", "directory.ts", "auth.ts", "oauth_routes.ts", "oauth_store.ts", "identity.ts"]) {
    const src = await fs.readFile(new URL(`./${f}`, import.meta.url), "utf8");
    assert(!/EAAA[A-Za-z0-9_-]{10,}/.test(src), `${f} contains what looks like a Square token`);
    assert(!/eyJ[A-Za-z0-9_-]{20,}\./.test(src), `${f} contains what looks like a JWT`);
  }
});

console.log(`\nprotocol + wiring: ${passed} passed, ${failures.length} failed\n`);
if (failures.length) {
  for (const f of failures) console.error("  ✗ " + f + "\n");
  process.exit(1);
}
console.log("  ✓ catalog mapping, order payload, status, PAM and tool surface all hold\n");
