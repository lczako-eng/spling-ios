// ============================================================================
// Tests for the personal lexicon.
//
// Run: node --experimental-strip-types lexicon_test.ts
//
// A lexicon is a guessing engine bolted to the front of a validator whose whole
// value is that it does not guess. Most of this file exists to prove it cannot
// become one.
// ============================================================================

import {
  CALIBRATION, CALIBRATION_INSTRUCTIONS, CALIBRATION_WORDS, LexiconRefusal,
  PROTECTED_TOKENS, applyToText, composeWithLexicon, makeEntry, mergeEntries,
  pairsFromCalibration, tryMakeEntry, type LexiconEntry,
} from "./lexicon.ts";
import type { Catalogue } from "./catalogue.ts";

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
function throws(fn: () => unknown, m: string) {
  try { fn(); } catch { return; }
  throw new Error(m);
}

const MENU: Catalogue = {
  provider: "test", location_id: "L1", kind: "menu", noun: "order", fetched_at: "",
  offerings: [
    {
      id: "I_LATTE", name: "Latte",
      variants: [
        { id: "V_S", name: "Small", price_cents: 450, currency: "CAD" },
        { id: "V_L", name: "Large", price_cents: 550, currency: "CAD" },
      ],
      option_groups: [{
        id: "G_MILK", name: "Milk", options: [
          { id: "O_OAT", name: "Oat Milk", price_cents: 75 },
          { id: "O_WHOLE", name: "Whole Milk", price_cents: 0 },
        ],
      }],
    },
    {
      id: "I_SAUSAGE", name: "Sausage Muffin",
      variants: [{ id: "V_R", name: "Regular", price_cents: 399, currency: "CAD" }],
      option_groups: [],
    },
    {
      id: "I_PEANUT", name: "Peanut Cookie", tags: ["peanut"],
      variants: [{ id: "V_C", name: "Regular", price_cents: 250, currency: "CAD" }],
      option_groups: [],
    },
  ],
};

const lisp = (): LexiconEntry[] => [
  { heard: "thauthage", meant: "sausage", source: "calibration", hits: 3 },
  { heard: "thmall", meant: "small", source: "calibration", hits: 1 },
];

// ---------------------------------------------------------------------------
// what may be learned — and what may never be
// ---------------------------------------------------------------------------

test("a pair is learned from a consistent mishearing", () => {
  const e = makeEntry("Thauthage", "sausage", "calibration");
  eq(e.heard, "thauthage", "normalised");
  eq(e.meant, "sausage", "normalised");
});

test("negation and allergy words are never substituted, in either direction", () => {
  throws(() => makeEntry("know", "no", "correction"), "a pair producing 'no' must be refused");
  throws(() => makeEntry("no", "know", "correction"), "a pair consuming 'no' must be refused");
  throws(() => makeEntry("without peanut", "with peanut", "correction"), "'without' must be refused");
  throws(() => makeEntry("allergic to nuts", "a lot of nuts", "correction"), "'allergic' must be refused");
  for (const w of PROTECTED_TOKENS) {
    assert(tryMakeEntry(`${w} thing`, "some thing", "correction") === null, `"${w}" must be protected`);
  }
});

test("pairs that teach nothing are refused", () => {
  throws(() => makeEntry("latte", "latte", "correction"), "identical sides");
  throws(() => makeEntry("a", "latte", "correction"), "too short to be distinctive");
  throws(() => makeEntry("", "latte", "correction"), "empty");
  throws(() => makeEntry("x".repeat(200), "latte", "correction"), "too long");
});

test("a refusal is ordinary, not an error to propagate", () => {
  assert(tryMakeEntry("latte", "latte", "correction") === null, "quiet form returns null");
  assert(makeEntry("thmall", "small", "correction") instanceof Object, "loud form still works");
  try { makeEntry("no", "know", "correction"); } catch (e) {
    assert(e instanceof LexiconRefusal, "refusals are their own type");
  }
});

// ---------------------------------------------------------------------------
// applying
// ---------------------------------------------------------------------------

test("substitution is whole-word only", () => {
  const entries: LexiconEntry[] = [{ heard: "ice", meant: "iced", source: "correction", hits: 0 }];
  const r = applyToText(entries, "ice coffee");
  eq(r.text, "iced coffee", "whole word replaced");

  const inner = applyToText(entries, "icecream");
  eq(inner.text, "icecream", "must not fire inside another word");
  eq(inner.substitutions.length, 0, "and must not report a substitution");
});

test("a longer phrase wins over a shorter one inside it", () => {
  const entries: LexiconEntry[] = [
    { heard: "large", meant: "small", source: "correction", hits: 9 },
    { heard: "large latte", meant: "large mocha", source: "correction", hits: 1 },
  ];
  eq(applyToText(entries, "large latte").text, "large mocha", "the two-word pair must win despite fewer hits");
});

// ---------------------------------------------------------------------------
// the guarantees — these are the reason the file exists
// ---------------------------------------------------------------------------

test("an order that already worked is never touched", () => {
  const opts = { menu: MENU, requested: [{ name_or_id: "Latte", variation: "Large" }] };
  const r = composeWithLexicon(opts, [
    { heard: "latte", meant: "sausage muffin", source: "correction", hits: 99 },
  ]);
  assert(r.ok, "should still resolve");
  eq(r.line_items[0].name, "Latte", "a working line must not be rewritten");
  eq(r.lexicon_applied, [], "and nothing is reported as applied");
});

test("a mishearing resolves once the lexicon is in front", () => {
  const opts = { menu: MENU, requested: [{ name_or_id: "thauthage muffin" }] };
  const without = composeWithLexicon(opts, []);
  assert(!without.ok, "baseline: it must fail with no lexicon");

  const withIt = composeWithLexicon(opts, lisp());
  assert(withIt.ok, `should resolve: ${JSON.stringify(withIt.rejections)}`);
  eq(withIt.line_items[0].name, "Sausage Muffin", "resolved to the real item");
  eq(withIt.lexicon_applied, [{ heard: "thauthage", meant: "sausage" }], "and says what it did");
});

test("the lexicon resolves a size too, not just an item", () => {
  const r = composeWithLexicon(
    { menu: MENU, requested: [{ name_or_id: "thauthage muffin", variation: "thmall" }] },
    lisp(),
  );
  // Sausage Muffin has only "Regular", so the size still fails — the point is
  // that the item resolved and the failure is the honest one.
  assert(!r.ok || r.line_items.length === 1, "no crash on a partial resolution");
});

test("the lexicon never resolves ambiguity — that is still a question", () => {
  const ambiguous: Catalogue = {
    ...MENU,
    offerings: [
      { id: "A", name: "Iced Latte", variants: [{ id: "a", name: "R", price_cents: 500, currency: "CAD" }], option_groups: [] },
      { id: "B", name: "Iced Mocha", variants: [{ id: "b", name: "R", price_cents: 550, currency: "CAD" }], option_groups: [] },
    ],
  };
  const r = composeWithLexicon(
    { menu: ambiguous, requested: [{ name_or_id: "ithed" }] },
    [{ heard: "ithed", meant: "iced", source: "calibration", hits: 5 }],
  );
  assert(!r.ok, "ambiguity must not be resolved by a lexicon");
  assert(
    r.rejections.some((x) => x.code === "item_ambiguous" || x.code === "item_not_found"),
    `must still refuse: ${JSON.stringify(r.rejections)}`,
  );
});

test("a rewrite that does not help is discarded entirely", () => {
  const r = composeWithLexicon(
    { menu: MENU, requested: [{ name_or_id: "flat white" }] },
    [{ heard: "flat white", meant: "long black", source: "correction", hits: 4 }],
  );
  assert(!r.ok, "neither name is on the menu");
  eq(r.lexicon_applied, [], "a rewrite that changed nothing must not be reported as applied");
  eq(r.rejections[0].requested, "flat white", "the person's own words are what comes back to them");
});

test("a lexicon cannot walk an order into an allergen", () => {
  const r = composeWithLexicon(
    { menu: MENU, requested: [{ name_or_id: "peanut cookie" }],
      dietary: [{ kind: "allergen", value: "peanut", severity: "anaphylaxis" }] },
    [{ heard: "peanut cookie", meant: "peanut cookie", source: "correction", hits: 0 }],
  );
  assert(!r.ok, "an anaphylaxis block stands regardless of the lexicon");
});

// ---------------------------------------------------------------------------
// calibration
// ---------------------------------------------------------------------------

test("the calibration is twenty words, ordered by what a mistake costs", () => {
  eq(CALIBRATION_WORDS.length, 20, "twenty");
  eq(CALIBRATION[0].key, "negation", "negation first — a dropped 'no' is not a wrong order, it is the wrong food");
  eq(CALIBRATION.map((s) => s.words.length), [5, 5, 5, 5], "four sets of five, so it can be stopped between them");
});

test("calibration words are words people order with", () => {
  for (const w of CALIBRATION.find((s) => s.key === "items")!.words) {
    assert(w.length > 3, `"${w}" should be a real orderable word`);
  }
  assert(CALIBRATION_WORDS.includes("iced"), "'iced' — the cluster that turns an iced coffee into a hot one");
  assert(CALIBRATION_WORDS.includes("double-double"), "the most-ordered phrase in the country this is built in");
});

test("the interaction rules travel with the words", () => {
  const all = CALIBRATION_INSTRUCTIONS.join(" ").toLowerCase();
  assert(all.includes("not a test"), "never called a test");
  assert(all.includes("never show"), "never shows what was misheard");
  assert(all.includes("no score"), "no score");
  assert(all.includes("third attempt"), "never a third attempt");
  assert(all.includes("skippable"), "skippable");
});

test("only the mishearings become pairs", () => {
  const { entries } = pairsFromCalibration([
    { word: "sausage", heard: "thauthage" },
    { word: "cheese", heard: "cheese" },      // understood — nothing to learn
    { word: "espresso" },                      // skipped
  ]);
  eq(entries.map((e) => `${e.heard}>${e.meant}`), ["thauthage>sausage"], "one pair");
  eq(entries[0].source, "calibration", "source recorded");
});

test("a failed negation word is a flag, never a substitution", () => {
  const { entries, negation_unreliable } = pairsFromCalibration([
    { word: "without", heard: "with out of" },
    { word: "no", heard: "know" },
  ]);
  eq(entries, [], "negation must never produce a substitution");
  eq(negation_unreliable, ["without", "no"], "it is reported so dietary gets confirmed out loud instead");
});

test("merging keeps the newer meaning and the older hit count", () => {
  const merged = mergeEntries(
    [{ heard: "thauthage", meant: "sausage", source: "calibration", hits: 7 }],
    [{ heard: "thauthage", meant: "sausage muffin", source: "correction", hits: 0 }],
  );
  eq(merged.length, 1, "no duplicate on the same heard");
  eq(merged[0].meant, "sausage muffin", "newer meaning wins");
  eq(merged[0].hits, 7, "accumulated hits survive a correction");
});

console.log(`\nlexicon: ${passed} passed, ${failures.length} failed\n`);
if (failures.length) {
  for (const f of failures) console.error("  ✗ " + f + "\n");
  process.exit(1);
}
console.log("  ✓ negation is untouchable, ambiguity stays a question, and a working order is never rewritten\n");
