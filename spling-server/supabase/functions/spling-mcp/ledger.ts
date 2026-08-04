// ============================================================================
// The accuracy ledger — shaping the record, before it is written.
//
// A correction is only worth storing if it can later answer a question. "This
// order was wrong" answers nothing; "Oat Milk was missing from this exact
// catalogue item, at this location, on an order composed in Thai" answers four
// of the five questions in docs/STRATEGY.md.
//
// So this module's job is to resolve a user's plain complaint against the order
// they are complaining about, and pin it to the specific line item and modifier
// where it can be counted. It never invents a link it cannot justify — an
// unattributed correction is still recorded, just as '(unspecified)'.
//
// Pure: no network, no database. Tested in ledger_test.ts.
// ============================================================================

import { normalize, type ResolvedLineItem } from "./compose.ts";

export type CorrectionKind =
  | "missing_item" | "wrong_item" | "wrong_modifier"
  | "wrong_quantity" | "quality" | "other";

export const CORRECTION_KINDS: CorrectionKind[] = [
  "missing_item", "wrong_item", "wrong_modifier", "wrong_quantity", "quality", "other",
];

export interface CorrectionReport {
  kind: string;
  /** What the user names as the problem, in their own words. */
  item_name?: string;
  received?: string;
  note?: string;
}

export interface ShapedCorrection {
  kind: CorrectionKind;
  item_name: string | null;
  line_item_index: number | null;
  catalog_object_id: string | null;
  modifier_name: string | null;
  modifier_object_id: string | null;
  received: string | null;
  note: string | null;
}

export class InvalidCorrection extends Error {}

/** Does this haystack contain the needle as a whole word or a contained run? */
function mentions(haystack: string, needle: string): boolean {
  if (!needle) return false;
  const h = normalize(haystack), n = normalize(needle);
  if (!n) return false;
  return h === n || h.includes(n) || n.includes(h);
}

/**
 * Attribute a complaint to a line item and, where the complaint is about a
 * modifier, to that modifier.
 *
 * Attribution order:
 *   1. the item name the user gave, matched against line item names
 *   2. the modifier name the user gave, matched against that order's modifiers
 *   3. a single-line order — unambiguous by construction
 *   4. nothing; recorded unattributed rather than guessed
 */
export function shapeCorrection(
  report: CorrectionReport,
  lineItems: ResolvedLineItem[],
): ShapedCorrection {
  const kind = String(report.kind ?? "") as CorrectionKind;
  if (!CORRECTION_KINDS.includes(kind)) {
    throw new InvalidCorrection(
      `Unknown correction kind "${report.kind}". Expected one of: ${CORRECTION_KINDS.join(", ")}.`,
    );
  }

  const said = (report.item_name ?? "").trim();
  const items = lineItems ?? [];

  let index: number | null = null;
  let modifierName: string | null = null;
  let modifierId: string | null = null;

  // 1 — the named item
  if (said) {
    const byItem = items.findIndex(
      (li) => mentions(li.name, said) || mentions(`${li.name} ${li.variation_name}`, said),
    );
    if (byItem >= 0) index = byItem;
  }

  // 2 — the named modifier, searched across the order when the item did not match
  if (said) {
    const scope = index === null ? items : [items[index]];
    for (const li of scope) {
      if (!li) continue;
      const hit = li.modifiers.find((m) => mentions(m.name, said));
      if (hit) {
        modifierName = hit.name;
        modifierId = hit.catalog_object_id;
        if (index === null) index = items.indexOf(li);
        break;
      }
    }
  }

  // 3 — a one-line order leaves nothing to be ambiguous about
  if (index === null && items.length === 1) index = 0;

  // For a modifier complaint on an attributed line with exactly one modifier,
  // that modifier is the only thing it can be about.
  if (kind === "wrong_modifier" && !modifierName && index !== null) {
    const mods = items[index]?.modifiers ?? [];
    if (mods.length === 1) {
      modifierName = mods[0].name;
      modifierId = mods[0].catalog_object_id;
    }
  }

  const line = index === null ? null : items[index] ?? null;

  return {
    kind,
    item_name: said || (line ? line.name : null),
    line_item_index: index,
    catalog_object_id: line ? line.catalog_object_id : null,
    modifier_name: modifierName,
    modifier_object_id: modifierId,
    received: report.received?.trim() || null,
    note: report.note?.trim() || null,
  };
}

/**
 * Accuracy as a percentage, with the honesty attached.
 *
 * A rate without its sample size is a marketing number. 384 is the sample
 * required for +/-5% at 95% confidence; below it we have an observation.
 */
export interface AccuracyReading {
  completed: number;
  corrected: number;
  accuracy_pct: number | null;
  confidence: "insufficient" | "low" | "moderate" | "high";
  quotable: boolean;
}

export function accuracy(completed: number, corrected: number): AccuracyReading {
  if (!Number.isFinite(completed) || completed < 0 || !Number.isFinite(corrected) || corrected < 0) {
    throw new InvalidCorrection("Accuracy inputs must be non-negative numbers.");
  }
  if (corrected > completed) {
    // Never possible from the SQL views, which join corrections to completed
    // orders. Guarded anyway: a >100% error rate should surface as a bug, not
    // as a negative accuracy figure quoted to a merchant.
    throw new InvalidCorrection("More corrections than completed orders — the denominator is wrong.");
  }

  const pct = completed === 0 ? null : Math.round((1 - corrected / completed) * 1000) / 10;
  const confidence: AccuracyReading["confidence"] =
    completed >= 100 ? "high" : completed >= 30 ? "moderate" : completed >= 10 ? "low" : "insufficient";

  return { completed, corrected, accuracy_pct: pct, confidence, quotable: completed >= 384 };
}
