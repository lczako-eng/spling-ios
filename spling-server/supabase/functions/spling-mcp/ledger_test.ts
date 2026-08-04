// ============================================================================
// Tests for the accuracy ledger.
//
// Run: node --experimental-strip-types ledger_test.ts
//
// The ledger is the moat that compounds, which means a correction recorded
// badly today is a question that cannot be answered in two years. These tests
// hold the attribution rules and the honesty of the accuracy figure.
// ============================================================================

import { shapeCorrection, accuracy, InvalidCorrection, CORRECTION_KINDS } from "./ledger.ts";
import type { ResolvedLineItem } from "./compose.ts";

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
function throws(fn: () => void, m: string) {
  try { fn(); } catch { return; }
  throw new Error(m);
}

const LATTE: ResolvedLineItem = {
  catalog_object_id: "VAR_LATTE_L", item_id: "ITEM_LATTE", name: "Latte",
  variation_name: "Large", qty: 1, base_cents: 550, line_cents: 625,
  modifiers: [{ catalog_object_id: "MOD_OAT", name: "Oat Milk", price_cents: 75 }],
};
const BURGER: ResolvedLineItem = {
  catalog_object_id: "VAR_BURGER", item_id: "ITEM_BURGER", name: "Cheeseburger",
  variation_name: "Regular", qty: 2, base_cents: 890, line_cents: 1780,
  modifiers: [
    { catalog_object_id: "MOD_NO_ONION", name: "No Onion", price_cents: 0 },
    { catalog_object_id: "MOD_EXTRA_CHEESE", name: "Extra Cheese", price_cents: 60 },
  ],
};

// ---------------------------------------------------------------------------
// attribution
// ---------------------------------------------------------------------------
test("attributes a complaint to the named item", () => {
  const c = shapeCorrection({ kind: "wrong_item", item_name: "Cheeseburger" }, [LATTE, BURGER]);
  eq(c.line_item_index, 1, "second line");
  eq(c.catalog_object_id, "VAR_BURGER", "pinned to the catalogue entry, not a free-text name");
});

test("attributes a modifier complaint to the exact modifier", () => {
  const c = shapeCorrection({ kind: "wrong_modifier", item_name: "oat milk" }, [LATTE, BURGER]);
  eq(c.modifier_name, "Oat Milk", "modifier resolved");
  eq(c.modifier_object_id, "MOD_OAT", "…with its catalogue id, so it can be counted");
  eq(c.line_item_index, 0, "and the line it came from");
});

test("finds the modifier even when the user names only the modifier", () => {
  const c = shapeCorrection({ kind: "missing_item", item_name: "extra cheese" }, [LATTE, BURGER]);
  eq(c.modifier_object_id, "MOD_EXTRA_CHEESE", "searched across the whole order");
  eq(c.line_item_index, 1, "attributed to the burger");
});

test("a one-line order needs no naming", () => {
  const c = shapeCorrection({ kind: "quality", note: "cold" }, [LATTE]);
  eq(c.line_item_index, 0, "unambiguous by construction");
  eq(c.item_name, "Latte", "item name filled from the order");
});

test("a modifier complaint on a line with one modifier resolves it", () => {
  const c = shapeCorrection({ kind: "wrong_modifier" }, [LATTE]);
  eq(c.modifier_object_id, "MOD_OAT", "only one thing it could be");
});

test("refuses to guess a modifier when the line has two", () => {
  const c = shapeCorrection({ kind: "wrong_modifier" }, [BURGER]);
  eq(c.line_item_index, 0, "line is known");
  eq(c.modifier_object_id, null, "but the modifier is not invented");
});

test("records an unattributable correction rather than dropping it", () => {
  const c = shapeCorrection({ kind: "other", note: "staff were great" }, [LATTE, BURGER]);
  eq(c.line_item_index, null, "no attribution");
  eq(c.catalog_object_id, null, "no fabricated link");
  eq(c.note, "staff were great", "but the record survives");
});

test("matches across diacritics and case, like the composer does", () => {
  const c = shapeCorrection({ kind: "wrong_item", item_name: "LATTE" }, [LATTE, BURGER]);
  eq(c.line_item_index, 0, "case-insensitive");
});

test("trims and nulls empty free text instead of storing blanks", () => {
  const c = shapeCorrection({ kind: "quality", received: "   ", note: "  too hot  " }, [LATTE]);
  eq(c.received, null, "blank becomes null");
  eq(c.note, "too hot", "trimmed");
});

test("rejects an unknown correction kind", () => {
  throws(() => shapeCorrection({ kind: "vibes" }, [LATTE]), "must reject unknown kinds");
});

test("every declared kind is accepted", () => {
  for (const k of CORRECTION_KINDS) {
    const c = shapeCorrection({ kind: k }, [LATTE]);
    eq(c.kind, k, `kind ${k}`);
  }
});

// ---------------------------------------------------------------------------
// accuracy honesty
// ---------------------------------------------------------------------------
test("accuracy is a percentage to one decimal", () => {
  const a = accuracy(100, 7);
  eq(a.accuracy_pct, 93, "93%");
  eq(a.confidence, "high", "n=100");
});

test("small samples are labelled, not hidden", () => {
  eq(accuracy(3, 0).confidence, "insufficient", "3 orders is not a measurement");
  eq(accuracy(12, 1).confidence, "low", "12");
  eq(accuracy(40, 2).confidence, "moderate", "40");
});

test("a rate is only quotable at n >= 384", () => {
  assert(!accuracy(383, 10).quotable, "383 is not enough for a public claim");
  assert(accuracy(384, 10).quotable, "384 is");
});

test("zero completed orders yields null, never 100%", () => {
  const a = accuracy(0, 0);
  eq(a.accuracy_pct, null, "no orders means no accuracy figure");
  eq(a.confidence, "insufficient", "and it says so");
});

test("more corrections than orders is a bug, not a negative accuracy", () => {
  throws(() => accuracy(10, 11), "must refuse an impossible denominator");
});

test("rejects nonsense inputs", () => {
  throws(() => accuracy(-1, 0), "negative completed");
  throws(() => accuracy(10, -1), "negative corrected");
  throws(() => accuracy(Number.NaN, 0), "NaN");
});

console.log(`\naccuracy ledger: ${passed} passed, ${failures.length} failed\n`);
if (failures.length) {
  for (const f of failures) console.error("  ✗ " + f + "\n");
  process.exit(1);
}
console.log("  ✓ corrections attribute correctly and accuracy never overstates itself\n");
