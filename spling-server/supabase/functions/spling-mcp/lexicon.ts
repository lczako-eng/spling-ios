// ============================================================================
// The personal lexicon.
//
// Design and reasoning: docs/LEXICON.md. The short version:
//
// Spling never hears anyone — recognition happens inside the assistant and MCP
// carries text. So this does not model how a person speaks. It models how their
// assistant mishears them: a table of (heard → meant) pairs belonging to one
// person, learned from their own corrections and from a short calibration.
//
// It is the same machinery as cross-language matching, not a second feature.
// compose.ts already strips diacritics so "lattét" resolves to "Latte"; this is
// that normalisation pass keyed to a person instead of to a script.
//
// Pure. No I/O. Tested like compose.ts, because the failure modes here are the
// expensive kind.
// ============================================================================

import { compose, normalize, type ComposeOptions, type CompositionResult, type RequestedItem } from "./compose.ts";

export const MAX_ENTRIES_PER_PROFILE = 500;
const MIN_TOKEN = 2;
const MAX_TOKEN = 60;

export interface LexiconEntry {
  /** What the assistant transcribed. Stored normalised. */
  heard: string;
  /** What the person meant. Stored normalised. */
  meant: string;
  /** Where it came from — affects nothing but is worth knowing when auditing. */
  source: "calibration" | "correction";
  /** How often it has fired. Used only to order candidates, never to guess. */
  hits: number;
}

export interface Substitution {
  heard: string;
  meant: string;
}

// ---------------------------------------------------------------------------
// Words this may never touch.
//
// A dropped "no" does not produce a wrong order. It produces the thing someone
// cannot eat. A probabilistic substitution has no business anywhere near
// negation, so the lexicon refuses to learn a pair that contains any of these
// on either side — rather than learning it and being careful later.
// ---------------------------------------------------------------------------
export const PROTECTED_TOKENS = [
  "no", "not", "none", "without", "hold", "skip", "free", "never",
  "allergy", "allergic", "allergen", "intolerant", "celiac", "coeliac",
];

const PROTECTED = new Set(PROTECTED_TOKENS);

function containsProtected(phrase: string): boolean {
  return normalize(phrase).split(" ").some((w) => PROTECTED.has(w));
}

export class LexiconRefusal extends Error {
  reason: string;
  constructor(reason: string) {
    super(reason);
    this.name = "LexiconRefusal";
    this.reason = reason;
  }
}

/**
 * Build an entry, or refuse. Refusal is the common case and is not an error
 * condition — most transcription noise is not worth learning.
 */
export function makeEntry(
  heardRaw: string,
  meantRaw: string,
  source: LexiconEntry["source"],
): LexiconEntry {
  const heard = normalize(heardRaw ?? "");
  const meant = normalize(meantRaw ?? "");

  if (!heard || !meant) throw new LexiconRefusal("Both sides of a pair are required.");
  if (heard.length < MIN_TOKEN || meant.length < MIN_TOKEN) {
    throw new LexiconRefusal("Too short to be distinctive; it would fire on everything.");
  }
  if (heard.length > MAX_TOKEN || meant.length > MAX_TOKEN) {
    throw new LexiconRefusal("Too long to be a word-level substitution.");
  }
  if (heard === meant) throw new LexiconRefusal("Nothing was misheard.");
  if (containsProtected(heard) || containsProtected(meant)) {
    // See PROTECTED_TOKENS above. This is the rule that matters most.
    throw new LexiconRefusal("Negation and allergy words are never substituted.");
  }
  return { heard, meant, source, hits: 0 };
}

/** Refusals are ordinary, so callers usually want the quiet form. */
export function tryMakeEntry(
  heard: string,
  meant: string,
  source: LexiconEntry["source"],
): LexiconEntry | null {
  try { return makeEntry(heard, meant, source); } catch { return null; }
}

// ---------------------------------------------------------------------------
// applying
// ---------------------------------------------------------------------------

/**
 * Rewrite one string. Whole-word only — a lexicon that fires inside other words
 * turns "iced" into nonsense everywhere it appears as a substring.
 *
 * Longer `heard` phrases win, so a two-word pair is not pre-empted by a
 * one-word pair that happens to sit inside it.
 */
export function applyToText(entries: LexiconEntry[], text: string): { text: string; substitutions: Substitution[] } {
  const words = normalize(text).split(" ").filter(Boolean);
  if (!words.length) return { text, substitutions: [] };

  const ordered = [...entries].sort((a, b) => {
    const byLength = b.heard.split(" ").length - a.heard.split(" ").length;
    return byLength !== 0 ? byLength : b.hits - a.hits;
  });

  const substitutions: Substitution[] = [];
  const out: string[] = [];

  let i = 0;
  while (i < words.length) {
    let matched = false;
    for (const e of ordered) {
      const parts = e.heard.split(" ");
      if (parts.length > words.length - i) continue;
      if (parts.every((p, k) => words[i + k] === p)) {
        out.push(e.meant);
        substitutions.push({ heard: e.heard, meant: e.meant });
        i += parts.length;
        matched = true;
        break;
      }
    }
    if (!matched) { out.push(words[i]); i += 1; }
  }

  return { text: out.join(" "), substitutions };
}

function rewriteItem(entries: LexiconEntry[], req: RequestedItem): { item: RequestedItem; substitutions: Substitution[] } {
  const subs: Substitution[] = [];
  const name = applyToText(entries, req.name_or_id);
  subs.push(...name.substitutions);

  let variation = req.variation;
  if (variation) {
    const v = applyToText(entries, variation);
    variation = v.text;
    subs.push(...v.substitutions);
  }

  let modifiers = req.modifiers;
  if (modifiers?.length) {
    modifiers = modifiers.map((m) => {
      const r = applyToText(entries, m);
      subs.push(...r.substitutions);
      return r.text;
    });
  }

  return { item: { ...req, name_or_id: name.text, variation, modifiers }, substitutions: subs };
}

// ---------------------------------------------------------------------------
// composing with a lexicon
// ---------------------------------------------------------------------------

export interface LexiconResult extends CompositionResult {
  /** Substitutions that were actually used. Empty when the lexicon did nothing. */
  lexicon_applied: Substitution[];
}

/**
 * The safe order of operations, and the reason this cannot become a guessing
 * engine bolted onto a validator that does not guess:
 *
 *   1. compose the request exactly as it arrived
 *   2. if — and only if — something failed to resolve, rewrite through the
 *      lexicon and compose again
 *   3. keep the second result only if it is strictly better
 *
 * The lexicon therefore never changes an order that already worked, never
 * turns a rejection into a different rejection, and never resolves ambiguity.
 * Ambiguity is still a question. compose.ts still decides.
 */
export function composeWithLexicon(opts: ComposeOptions, entries: LexiconEntry[]): LexiconResult {
  const first = compose(opts);
  if (!entries.length || !first.rejections.length) {
    return { ...first, lexicon_applied: [] };
  }

  // Only the lines that failed are rewritten. A line that resolved is left
  // exactly as the person said it.
  const failed = new Set(first.rejections.map((r) => r.requested));
  const substitutions: Substitution[] = [];
  const requested = opts.requested.map((req) => {
    if (!failed.has(req.name_or_id)) return req;
    const r = rewriteItem(entries, req);
    substitutions.push(...r.substitutions);
    return r.item;
  });

  if (!substitutions.length) return { ...first, lexicon_applied: [] };

  const second = compose({ ...opts, requested });

  // Strictly better, or it did not happen. Equal counts keep the original, so a
  // lexicon can never trade one person's rejection for another's.
  if (second.rejections.length >= first.rejections.length) {
    return { ...first, lexicon_applied: [] };
  }

  const used = new Set(second.line_items.map((l) => normalize(l.name)));
  return {
    ...second,
    lexicon_applied: substitutions.filter((s) => used.has(s.meant) || [...used].some((u) => u.includes(s.meant))),
  };
}

// ---------------------------------------------------------------------------
// calibration
//
// Twenty words, ordered by what a mistake costs. Every one is a word someone
// actually orders with — a phonetics passage would characterise a speaker's
// phonology, and we do not need a phonological model. We need to resolve menu
// items and nothing else. See docs/LEXICON.md for why each set is here.
// ---------------------------------------------------------------------------

export interface CalibrationSet {
  key: string;
  /** Shown to the person. Never mentions their speech — the system is being
      calibrated, they are not being assessed. */
  title: string;
  words: string[];
}

export const CALIBRATION: CalibrationSet[] = [
  {
    key: "negation",
    title: "Leaving things out",
    words: ["no", "without", "hold the", "none", "allergic"],
  },
  {
    key: "sizes",
    title: "Sizes",
    words: ["small", "medium", "large", "extra large", "double-double"],
  },
  {
    key: "quantity",
    title: "How many",
    words: ["one", "two", "three", "ten", "fifteen"],
  },
  {
    key: "items",
    title: "Things to order",
    words: ["sausage", "cheese", "iced", "espresso", "croissant"],
  },
];

export const CALIBRATION_WORDS: string[] = CALIBRATION.flatMap((s) => s.words);

/**
 * The rules the assistant is handed along with the words. These are not
 * suggestions — get them wrong and the feature is worse than not shipping,
 * because the people it is for have spent their lives being assessed on exactly
 * this. Kept next to the data so they cannot be lost in a rewrite.
 */
export const CALIBRATION_INSTRUCTIONS = [
  "This is not a test and must never be called one. The system is being calibrated; the person is not being assessed.",
  "Never show the person what was misheard. Store it, never display it.",
  "No score, no percentage, no accuracy count. Say nothing that sounds like marking.",
  "Every word is skippable, and the whole thing is resumable later. Do not ask why they stopped.",
  "Never ask for a third attempt at a word. Two, then move on — a third request is the drive-through experience this exists to abolish.",
  "After the first set, show one concrete thing it now gets right. Motivation before completion.",
  "They may swap any word for another without giving a reason.",
  "Read the words in whatever language the person is already using.",
];

export interface CalibrationResponse {
  /** The word we asked for. */
  word: string;
  /** What the assistant transcribed. Absent means skipped. */
  heard?: string;
}

/**
 * Turn calibration answers into entries. A response that matched is not a pair
 * — there is nothing to learn from being understood — and the negation set is
 * refused by makeEntry, which is the point of asking about it: its value is
 * telling us whether negation survives at all, not building substitutions.
 */
export function pairsFromCalibration(responses: CalibrationResponse[]): {
  entries: LexiconEntry[];
  /** Negation words that did not come through. Never becomes a substitution;
      it is a reason to confirm dietary constraints out loud, permanently. */
  negation_unreliable: string[];
} {
  const entries: LexiconEntry[] = [];
  const negation_unreliable: string[] = [];
  const negationWords = new Set(
    CALIBRATION.find((s) => s.key === "negation")!.words.map(normalize),
  );

  for (const r of responses) {
    if (!r.heard) continue;
    const want = normalize(r.word);
    const got = normalize(r.heard);
    if (!want || !got || want === got) continue;

    if (negationWords.has(want)) { negation_unreliable.push(r.word); continue; }

    const entry = tryMakeEntry(got, want, "calibration");
    if (entry) entries.push(entry);
  }

  return { entries, negation_unreliable };
}

/** Newest wins on a repeated `heard`, and hits accumulate rather than reset. */
export function mergeEntries(existing: LexiconEntry[], incoming: LexiconEntry[]): LexiconEntry[] {
  const byHeard = new Map(existing.map((e) => [e.heard, { ...e }]));
  for (const e of incoming) {
    const prior = byHeard.get(e.heard);
    byHeard.set(e.heard, prior ? { ...e, hits: prior.hits } : e);
  }
  return [...byHeard.values()].slice(0, MAX_ENTRIES_PER_PROFILE);
}
