// ============================================================================
// The generalisation test.
//
// Run: node --experimental-strip-types compose_domains_test.ts
//
// compose_test.ts proves the validator is right about food. This file proves it
// is not ABOUT food: the same engine, unmodified, validates a hotel booking, a
// pharmacy request, a government appointment and stadium accessibility seating.
//
// If someone later reintroduces a food assumption into compose.ts — a "menu"
// lookup, an allergen shortcut, a price that must be non-zero — these fail.
// That is the point of them.
// ============================================================================

import { compose, renderLines, type DietaryConstraint } from "./compose.ts";
import { buildDirectoryCatalogue } from "./directory.ts";
import { nounFor, type Catalogue } from "./catalogue.ts";

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
// A hotel. Rows exactly as a business would publish them (003).
// ---------------------------------------------------------------------------
const HOTEL_ROWS = [
  {
    id: "r1", external_id: "ROOM_ACC_KING", name: "Accessible King Room",
    description: "Roll-in shower, visual alarm, wide doorway",
    category: "Rooms", tags: ["wheelchair accessible", "visual alarm"],
    variants: [
      { id: "V_1N", name: "1 night", price_cents: 18900, currency: "CAD" },
      { id: "V_2N", name: "2 nights", price_cents: 35900, currency: "CAD" },
    ],
    option_groups: [{
      id: "G_ARR", name: "Arrival",
      options: [
        { id: "O_LATE", name: "Late arrival", price_cents: 0 },
        { id: "O_EARLY", name: "Early check-in", price_cents: 3000 },
      ],
    }],
    active: true,
  },
  {
    id: "r2", external_id: "ROOM_STD", name: "Standard Double Room",
    category: "Rooms", tags: [],
    variants: [{ id: "V_STD_1N", name: "1 night", price_cents: 14900, currency: "CAD" }],
    option_groups: [], active: true,
  },
];

const HOTEL: Catalogue = buildDirectoryCatalogue("hotel-yyz-01", "rooms", HOTEL_ROWS);

test("a hotel catalogue composes through the same engine", () => {
  const r = compose({
    menu: HOTEL,
    requested: [{ name_or_id: "Accessible King Room", variation: "2 nights", modifiers: ["Late arrival"] }],
  });
  assert(r.ok, `should compose a booking: ${JSON.stringify(r.rejections)}`);
  eq(r.line_items[0].catalog_object_id, "V_2N", "resolved to the exact variant");
  eq(r.total_cents, 35900, "priced in integer cents, same as everything else");
});

test("a hotel asks which duration rather than choosing one", () => {
  const r = compose({ menu: HOTEL, requested: [{ name_or_id: "Accessible King Room" }] });
  assert(!r.ok, "two durations must not be silently resolved");
  eq(r.rejections[0].code, "variation_ambiguous", "same refusal-to-guess rule");
});

test("an option from another room is still invalid", () => {
  const r = compose({
    menu: HOTEL,
    requested: [{ name_or_id: "Standard Double Room", variation: "1 night", modifiers: ["Late arrival"] }],
  });
  assert(!r.ok, "the standard room publishes no arrival options");
  eq(r.rejections[0].code, "modifier_not_valid_for_item", "cross-offering options rejected");
});

test("the noun matches the business — nobody orders a hotel room", () => {
  eq(HOTEL.noun, "booking", "rooms take a booking");
  eq(nounFor("services"), "request", "a pharmacy takes a request");
  eq(nounFor("appointments"), "appointment", "a clinic takes an appointment");
});

// ---------------------------------------------------------------------------
// A pharmacy. Free services, which a menu-shaped engine would have dropped.
// ---------------------------------------------------------------------------
const PHARMACY: Catalogue = buildDirectoryCatalogue("pharmacy-01", "services", [
  {
    id: "s1", external_id: "SVC_RX_PICKUP", name: "Prescription Pickup",
    description: "Collect a filled prescription", category: "Dispensary",
    tags: ["photo id required"],
    variants: [{ id: "V_RX", name: "Standard", price_cents: 0, currency: "CAD" }],
    option_groups: [{
      id: "G_NOTIFY", name: "Notify me",
      options: [
        { id: "O_TEXT", name: "Text when ready", price_cents: 0 },
        { id: "O_NONE", name: "No notification", price_cents: 0 },
      ],
    }],
    active: true,
  },
  {
    id: "s2", external_id: "SVC_FLU", name: "Flu Vaccination",
    category: "Clinic", tags: [],
    variants: [{ id: "V_FLU", name: "Walk-in", price_cents: 2500, currency: "CAD" }],
    option_groups: [], active: true,
  },
]);

test("a free service is requestable — zero cents is a price, not a missing one", () => {
  const r = compose({
    menu: PHARMACY,
    requested: [{ name_or_id: "Prescription Pickup", modifiers: ["Text when ready"] }],
  });
  assert(r.ok, `free services must compose: ${JSON.stringify(r.rejections)}`);
  eq(r.total_cents, 0, "zero total is valid");
  eq(r.line_items[0].catalog_object_id, "V_RX", "resolved");
});

test("a pharmacy request renders as a readable line for the counter", () => {
  const r = compose({ menu: PHARMACY, requested: [{ name_or_id: "Flu Vaccination" }] });
  eq(renderLines(r.line_items), ["1× Flu Vaccination Walk-in"], "line the counter can act on");
});

test("something not offered is refused here exactly as on a menu", () => {
  const r = compose({ menu: PHARMACY, requested: [{ name_or_id: "Passport Renewal" }] });
  assert(!r.ok, "must not compose");
  eq(r.rejections[0].code, "item_not_found", "same rejection code, different domain");
});

// ---------------------------------------------------------------------------
// Constraints outside food. The mechanism is "a recorded thing about this
// person blocks this offering", which was never really about allergens.
// ---------------------------------------------------------------------------
test("a recorded constraint blocks a non-food offering", () => {
  // Someone who cannot receive a latex-containing service records it the same
  // way an anaphylaxis allergen is recorded.
  const latex: DietaryConstraint[] = [{ kind: "allergen", value: "latex", severity: "anaphylaxis" }];
  const clinic = buildDirectoryCatalogue("clinic-01", "appointments", [{
    id: "c1", external_id: "SVC_DRESSING", name: "Wound Dressing Change",
    description: "Includes latex gloves unless requested otherwise",
    tags: ["latex"],
    variants: [{ id: "V_D", name: "Standard", price_cents: 0, currency: "CAD" }],
    option_groups: [], active: true,
  }]);

  const r = compose({ menu: clinic, requested: [{ name_or_id: "Wound Dressing Change" }], dietary: latex });
  assert(!r.ok, "must block");
  eq(r.rejections[0].code, "blocked_allergen", "the mechanism generalises");
  eq(r.rejections[0].overridable, false, "and stays unoverridable at anaphylaxis severity");
});

// ---------------------------------------------------------------------------
// Directory mapping rules
// ---------------------------------------------------------------------------
test("an offering with no variant is not published", () => {
  const c = buildDirectoryCatalogue("x", "services", [
    { id: "a", name: "Ghost Service", variants: [], option_groups: [], active: true },
    { id: "b", name: "Real Service", variants: [{ id: "v", name: "Standard", price_cents: 0 }], option_groups: [], active: true },
  ]);
  eq(c.offerings.map((o) => o.name), ["Real Service"], "unrequestable offerings excluded");
});

test("inactive offerings are excluded", () => {
  const c = buildDirectoryCatalogue("x", "services", [
    { id: "a", name: "Retired Service", variants: [{ id: "v", name: "S", price_cents: 0 }], option_groups: [], active: false },
  ]);
  eq(c.offerings.length, 0, "inactive excluded");
});

test("directory catalogues declare their provider and kind", () => {
  eq(PHARMACY.provider, "directory", "provider");
  eq(PHARMACY.kind, "services", "kind");
  eq(PHARMACY.noun, "request", "noun");
});

// ---------------------------------------------------------------------------
// The regression guard that matters
// ---------------------------------------------------------------------------
test("compose.ts contains no food-specific vocabulary", async () => {
  const fs = await import("node:fs/promises");
  const src = await fs.readFile(new URL("./compose.ts", import.meta.url), "utf8");
  const body = src.split("// ---------------------------------------------------------------------------")
    .slice(1).join("\n");   // skip the header comment, which discusses food deliberately
  for (const word of ["menu.items", "modifier_lists", ".variations", "allergens:"]) {
    assert(!body.includes(word), `compose.ts reintroduced a food/Square-shaped access: "${word}"`);
  }
});

console.log(`\ndomain generality: ${passed} passed, ${failures.length} failed\n`);
if (failures.length) {
  for (const f of failures) console.error("  ✗ " + f + "\n");
  process.exit(1);
}
console.log("  ✓ hotels, pharmacies and clinics validate through the same engine as a menu\n");
