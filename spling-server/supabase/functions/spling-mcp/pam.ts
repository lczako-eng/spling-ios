// ============================================================================
// PAM (Portable AI Memory) export.
//
// The spec is explicit: conform to the existing standard rather than invent a
// format. This is the promise that the profile is genuinely the user's — they
// can take it and leave, and nothing here is designed to make that hard.
//
// A note on what is included: the communication profile IS exported, because
// it belongs to the user and portability is the entire point. It is exported
// only here, only to the person it describes, and it is never transmitted to a
// merchant by any other path in this server.
// ============================================================================

import type { DietaryConstraint } from "./compose.ts";
import type { CommunicationProfile, OrderRow, Profile } from "./store.ts";

export const PAM_SCHEMA = "portable-ai-memory/v1.0";

export interface PamExport {
  schema: string;
  exported_at: string;
  subject: { id: string; display_name: string | null };
  memories: Array<{
    type: string;
    key: string;
    value: unknown;
    confidence: number;
    source: string;
    updated_at?: string;
  }>;
}

export function toPam(input: {
  profile: Profile;
  communication: CommunicationProfile | null;
  dietary: DietaryConstraint[];
  history: OrderRow[];
  exportedAt?: string;
}): PamExport {
  const { profile, communication, dietary, history } = input;
  const memories: PamExport["memories"] = [];

  memories.push({
    type: "preference",
    key: "language.compose",
    value: profile.compose_language,
    confidence: 1,
    source: "spling.user_declared",
  });
  memories.push({
    type: "preference",
    key: "language.receipt",
    value: profile.receipt_language,
    confidence: 1,
    source: "spling.user_declared",
  });

  if (communication) {
    memories.push({
      type: "accessibility",
      key: "communication.mode",
      value: communication.communication_mode,
      confidence: 1,
      source: "spling.user_declared",
    });
    if (communication.caretaker_staging_enabled) {
      memories.push({
        type: "accessibility",
        key: "communication.caregiver_staging",
        value: true,
        confidence: 1,
        source: "spling.user_declared",
      });
    }
    if (communication.notes_private) {
      memories.push({
        type: "accessibility",
        key: "communication.notes",
        value: communication.notes_private,
        confidence: 1,
        source: "spling.user_declared",
      });
    }
  }

  for (const d of dietary) {
    memories.push({
      type: d.kind === "allergen" ? "health" : "preference",
      key: `dietary.${d.kind}.${d.value}`,
      value: { value: d.value, severity: d.severity },
      confidence: 1,
      source: "spling.user_declared",
    });
  }

  // "The usual" — derived, so it carries lower confidence than a declaration.
  const counts = new Map<string, number>();
  for (const o of history) {
    for (const li of o.line_items ?? []) {
      const label = `${li.name}${li.variation_name && li.variation_name !== "Regular" ? " " + li.variation_name : ""}` +
        (li.modifiers?.length ? ` · ${li.modifiers.map((m) => m.name).join(", ")}` : "");
      counts.set(label, (counts.get(label) ?? 0) + li.qty);
    }
  }
  const ranked = [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10);
  for (const [label, n] of ranked) {
    memories.push({
      type: "habit",
      key: "ordering.frequent_item",
      value: { item: label, times: n },
      confidence: Math.min(0.95, 0.5 + n / 20),
      source: "spling.observed",
    });
  }

  return {
    schema: PAM_SCHEMA,
    exported_at: input.exportedAt ?? new Date().toISOString(),
    subject: { id: profile.id, display_name: profile.display_name },
    memories,
  };
}
