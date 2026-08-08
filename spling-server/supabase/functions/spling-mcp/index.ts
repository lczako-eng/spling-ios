// ============================================================================
// Spling MCP Server — the connector.
//
// Deploy:  supabase functions deploy spling-mcp --no-verify-jwt
// Secrets: supabase secrets set SQUARE_ACCESS_TOKEN=... SQUARE_ENV=sandbox \
//            SUPABASE_URL=... SUPABASE_ANON_KEY=... SUPABASE_SERVICE_ROLE_KEY=...
//
// Transport: MCP Streamable HTTP (POST JSON-RPC 2.0). Remote HTTPS only —
// ChatGPT does not accept stdio servers, so a hosted endpoint is mandatory.
//
// Auth: OAuth 2.1 + Dynamic Client Registration, with sign-in delegated to
// Google, Apple or an email link. See AUTH NOTE at the bottom.
//
// The rule this whole file exists to enforce: the model proposes, the
// validator disposes. Nothing reaches a merchant that compose.ts has not
// resolved to exact catalog IDs.
// ============================================================================

import { compose, pickupCode, renderLines, type RequestedItem } from "./compose.ts";
import {
  CALIBRATION, CALIBRATION_INSTRUCTIONS, composeWithLexicon, mergeEntries,
  pairsFromCalibration, type CalibrationResponse, type LexiconEntry,
} from "./lexicon.ts";
import { defaultLocationId, getOrder, mapSquareState, SquareError } from "./square.ts";
import "./square.ts";   // registers the POS rail
import {
  addCorrection, addDietary, createDraftOrder, ensureMerchant, ensureProfile,
  findMerchant, getCommunicationProfile, getDietary, getOrderRow, listHistory, logEvent,
  merchantAccuracy, patchOrder, removeDietary, updateProfile,
  upsertCommunicationProfile, getLexicon, putLexicon, getCalibration, upsertCalibration,
} from "./store.ts";
import { toPam } from "./pam.ts";
import { shapeCorrection, InvalidCorrection } from "./ledger.ts";
import { getProvider, type Catalogue } from "./catalogue.ts";
import "./directory.ts";   // registers the non-POS rail
import { handleOAuth, subjectFromAccessToken } from "./oauth_routes.ts";
import { issuerFrom, wwwAuthenticate } from "./auth.ts";

const SPLING_BEARER = Deno.env.get("SPLING_BEARER") ?? "";
const SERVER_VERSION = "0.7.0";

// ---------------------------------------------------------------------------
// Tool surface — the nine tools, final.
// Descriptions are written for the model: they say what a tool guarantees, so
// the assistant stops trying to be clever about menus it has not fetched.
// ---------------------------------------------------------------------------
const TOOLS = [
  {
    name: "get_catalog",
    description:
      "Get what a business currently offers at a location — menu items, services, rooms, appointments " +
      "or seating — with exact prices in cents and the valid options for each. Always call this before " +
      "composing. A transaction may only contain entries that appear here. The response includes " +
      "transaction_noun (order / request / booking / appointment): use that word with the user.",
    inputSchema: {
      type: "object",
      properties: {
        location_id: { type: "string", description: "The business's location ID. Omit for the default location." },
      },
    },
  },
  {
    name: "compose_order",
    description:
      "Validate a proposed transaction against the live catalogue and price it — an order, a booking, an " +
      "appointment or a request, whichever this business deals in. Accepts items in ANY language — " +
      "resolve what the user meant into candidate names, and this tool will match them to exact catalogue " +
      "entries or reject them with a reason. It never guesses: ambiguity is returned as a question. " +
      "Dietary constraints on the profile are enforced here, before the order exists. Returns a draft " +
      "order_id you pass to place_order. This tool does not charge anything.",
    inputSchema: {
      type: "object",
      required: ["items"],
      properties: {
        location_id: { type: "string" },
        items: {
          type: "array",
          description: "Candidate line items. Names may be approximate; the validator resolves or rejects them.",
          items: {
            type: "object",
            required: ["name_or_id"],
            properties: {
              name_or_id: { type: "string", description: "Item name in any language, or an exact ID from get_catalog." },
              qty: { type: "integer", minimum: 1, maximum: 50 },
              variation: { type: "string", description: "Size or variation name, e.g. 'Large'." },
              modifiers: { type: "array", items: { type: "string" } },
            },
          },
        },
        user_utterance: {
          type: "string",
          description: "What the user actually said, in their own language. Stored for their history only; never sent to the merchant.",
        },
        utterance_language: { type: "string", description: "BCP 47 tag of user_utterance, e.g. 'hu'." },
        overrides: {
          type: "array",
          items: { type: "string" },
          description: "Dietary values the user has explicitly confirmed overriding. Never overrides an anaphylaxis-severity allergen.",
        },
      },
    },
  },
  {
    name: "place_order",
    description:
      "Submit a composed transaction to the business and return a reference code, plus a secure Square " +
      "checkout link when that business takes payment through Spling. Businesses without a point of " +
      "sale — a pharmacy, hotel desk or service counter — return a reference and no link, which is " +
      "correct, not an error. Spling never handles card data. Call only after compose_order returned ok.",
    inputSchema: {
      type: "object",
      required: ["order_id"],
      properties: { order_id: { type: "string" }, location_id: { type: "string" } },
    },
  },
  {
    name: "get_order_status",
    description:
      "Current status, reference code and checkout link for one transaction. Reads live state from the " +
      "business rather than from anything Spling cached.",
    inputSchema: { type: "object", required: ["order_id"], properties: { order_id: { type: "string" } } },
  },
  {
    name: "get_profile",
    description:
      "Read the user's ordering profile: languages, dietary constraints, and communication preferences. " +
      "Call this before composing so language and allergens are applied without asking the user to repeat them.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "update_profile",
    description:
      "Update languages, dietary constraints, or communication preferences. Use severity 'anaphylaxis' only " +
      "when the user describes a severe allergy — it becomes a hard block that cannot be overridden.",
    inputSchema: {
      type: "object",
      properties: {
        compose_language: { type: "string", description: "BCP 47 tag the user speaks to their assistant." },
        receipt_language: { type: "string", description: "BCP 47 tag for their own receipts and history." },
        display_name: { type: "string" },
        communication_mode: {
          type: "string",
          enum: ["none", "nonverbal", "speech_difference", "deaf", "hoh", "aac_user"],
        },
        caretaker_staging_enabled: { type: "boolean" },
        add_dietary: {
          type: "array",
          items: {
            type: "object",
            required: ["kind", "value", "severity"],
            properties: {
              kind: { type: "string", enum: ["allergen", "diet", "dislike"] },
              value: { type: "string" },
              severity: { type: "string", enum: ["preference", "strict", "anaphylaxis"] },
            },
          },
        },
        remove_dietary: { type: "array", items: { type: "string" } },
        calibration_responses: {
          type: "array",
          description:
            "Answers to a voice calibration set from get_profile. For each word asked, send what you " +
            "transcribed. Omit 'heard' when the person skipped it. Never tell the user what was misheard.",
          items: {
            type: "object",
            required: ["word"],
            properties: {
              word: { type: "string", description: "The word that was asked for." },
              heard: { type: "string", description: "What you transcribed. Omit if skipped." },
            },
          },
        },
        calibration_sets_done: {
          type: "array",
          items: { type: "string" },
          description: "Keys of calibration sets completed in this pass, so they are not asked again.",
        },
      },
    },
  },
  {
    name: "get_history",
    description:
      "The user's past orders, most recent first, with a ranked 'usual' — the items they order most. " +
      "Use it to answer 'the usual' without guessing.",
    inputSchema: {
      type: "object",
      properties: { limit: { type: "integer", minimum: 1, maximum: 50 } },
    },
  },
  {
    name: "submit_correction",
    description:
      "Record what actually arrived against what was ordered. This is the accuracy ledger: it is how a " +
      "per-merchant accuracy record accumulates. Call it whenever the user reports a problem with an order.",
    inputSchema: {
      type: "object",
      required: ["order_id", "kind"],
      properties: {
        order_id: { type: "string" },
        kind: { type: "string", enum: ["missing_item", "wrong_item", "wrong_modifier", "wrong_quantity", "quality", "other"] },
        item_name: { type: "string" },
        received: { type: "string", description: "What actually arrived, in the user's words." },
        note: { type: "string" },
      },
    },
  },
  {
    name: "export_profile",
    description:
      "Export the user's profile in PAM (Portable AI Memory) JSON so they can take it to any other " +
      "assistant or service. The profile belongs to the user; this is how they leave.",
    inputSchema: { type: "object", properties: {} },
  },
];

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

function idem(): string { return crypto.randomUUID(); }

/**
 * A location belongs to a rail. Square is the default because it is the first
 * application; a pharmacy or hotel published through migration 003 resolves to
 * the directory provider. compose.ts never learns which one it got.
 */
async function catalogueFor(locationId: string): Promise<Catalogue> {
  const merchant = await findMerchant(locationId);
  return getProvider(merchant?.provider ?? "square").getCatalogue(locationId);
}

async function resolveLocation(args: Record<string, unknown>): Promise<string> {
  return (args.location_id as string) || await defaultLocationId();
}

/**
 * The authenticated subject — one real person.
 *
 * OAuth resolves to a verified subject. The shared bearer, when configured,
 * resolves every caller to ONE subject, which is correct for a single-tenant
 * sandbox and wrong the moment two people use it: they would share a profile,
 * including one person's allergens. It stays only as a local development path
 * and is refused whenever OAuth is available.
 */
async function subjectFrom(req: Request): Promise<string> {
  const viaOAuth = await subjectFromAccessToken(req);
  if (viaOAuth) return viaOAuth;
  return Deno.env.get("SPLING_DEFAULT_SUBJECT") ?? "00000000-0000-0000-0000-000000000001";
}

// ---------------------------------------------------------------------------
// tools
// ---------------------------------------------------------------------------

async function callTool(name: string, args: Record<string, unknown>, req: Request): Promise<unknown> {
  const authUserId = await subjectFrom(req);

  switch (name) {
    // -----------------------------------------------------------------------
    case "get_catalog": {
      const locationId = await resolveLocation(args);
      const menu = await catalogueFor(locationId);
      return {
        location_id: menu.location_id,
        fetched_at: menu.fetched_at,
        catalogue_kind: menu.kind,
        transaction_noun: menu.noun,
        note: `Prices are integer cents. Only these entries may be requested. This business takes a ${menu.noun}.`,
        items: menu.offerings.map((i) => ({
          id: i.id,
          name: i.name,
          category: i.category,
          description: i.description,
          variations: i.variants.map((v) => ({ id: v.id, name: v.name, price_cents: v.price_cents, currency: v.currency })),
          modifiers: i.option_groups.flatMap((l) => l.options.map((m) => ({ id: m.id, name: m.name, price_cents: m.price_cents }))),
        })),
      };
    }

    // -----------------------------------------------------------------------
    case "compose_order": {
      const locationId = await resolveLocation(args);
      const requested = (args.items ?? []) as RequestedItem[];
      if (!Array.isArray(requested) || requested.length === 0) {
        return { ok: false, error: "no_items", message: "compose_order needs at least one item." };
      }

      const profile = await ensureProfile(authUserId);
      const dietary = await getDietary(profile.id);
      const menu = await catalogueFor(locationId);

      // The lexicon runs only where the person's own words failed to resolve,
      // and only keeps a rewrite that is strictly better — so it can never
      // change an order that already worked, and never resolves an ambiguity.
      // See lexicon.ts and docs/LEXICON.md.
      const lexicon = (await getLexicon(profile.id).catch(() => [])) as LexiconEntry[];
      const result = composeWithLexicon({
        menu,
        requested,
        dietary,
        overrides: (args.overrides ?? []) as string[],
      }, lexicon);

      if (!result.ok) {
        // Nothing is persisted for a failed composition — there is no order.
        return {
          ok: false,
          rejections: result.rejections,
          warnings: result.warnings,
          message:
            "This order was not created. Every rejection above must be resolved with the user before " +
            "composing again — do not substitute or assume.",
        };
      }

      const merchantId = await ensureMerchant(locationId, `Location ${locationId}`);
      const order = await createDraftOrder({
        profile_id: profile.id,
        merchant_id: merchantId,
        line_items: result.line_items,
        total_cents: result.total_cents,
        currency: result.currency,
        user_utterance: (args.user_utterance as string) ?? null,
        utterance_language: (args.utterance_language as string) ?? null,
      });

      for (const ev of result.events) await logEvent(order.id, ev.event, ev.detail);

      return {
        ok: true,
        order_id: order.id,
        lines: renderLines(result.line_items),
        line_items: result.line_items,
        total_cents: result.total_cents,
        currency: result.currency,
        warnings: result.warnings,
        next: "Show the user these lines and the total, then call place_order to get a checkout link.",
      };
    }

    // -----------------------------------------------------------------------
    case "place_order": {
      const profile = await ensureProfile(authUserId);
      const orderId = String(args.order_id ?? "");
      const row = await getOrderRow(orderId, profile.id);
      if (!row) return { ok: false, error: "order_not_found" };
      if (row.status !== "composed") {
        return {
          ok: false,
          error: "wrong_state",
          status: row.status,
          message: `This ${row.status} transaction cannot be placed; only a composed one can.`,
        };
      }

      const locationId = await resolveLocation(args);
      const merchant = await findMerchant(locationId);
      const provider = getProvider(merchant?.provider ?? "square");
      const code = pickupCode();

      const submitted = await provider.submit({
        locationId,
        lineItems: row.line_items,
        reference: code,
        idempotencyKey: idem(),
        totalCents: row.total_cents,
      });

      if (submitted.status === "failed") {
        await patchOrder(row.id, { status: "failed", square_order_id: submitted.external_id });
        await logEvent(row.id, "total_mismatch", { ours: row.total_cents, rail: submitted.total_cents });
        return {
          ok: false,
          error: "total_mismatch",
          message: "The business's price changed since this was composed. Compose it again.",
          ours_cents: row.total_cents,
          merchant_cents: submitted.total_cents,
        };
      }

      const updated = await patchOrder(row.id, {
        square_order_id: submitted.external_id,
        checkout_url: submitted.checkout_url,
        pickup_code: code,
        status: submitted.status,
      });
      await logEvent(row.id, "submitted", { provider: provider.name, reference: code, paid_rail: !!submitted.checkout_url });

      return {
        ok: true,
        order_id: updated.id,
        pickup_code: code,
        checkout_url: submitted.checkout_url,
        total_cents: updated.total_cents,
        currency: updated.currency,
        lines: renderLines(row.line_items),
        // A pharmacy or service desk has no payment leg. Saying so keeps the
        // assistant from inventing a checkout step that does not exist.
        next: submitted.checkout_url
          ? "Give the user the checkout link and the reference code. Spling never sees card details."
          : "Give the user the reference code. This business takes no payment through Spling — the code is what they show at the counter.",
      };
    }

    // -----------------------------------------------------------------------
    case "get_order_status": {
      const profile = await ensureProfile(authUserId);
      const row = await getOrderRow(String(args.order_id ?? ""), profile.id);
      if (!row) return { ok: false, error: "order_not_found" };

      let status = row.status;
      if (row.square_order_id) {   // only a POS-backed transaction has live state to sync
        try {
          const sq = await getOrder(row.square_order_id);
          const mapped = mapSquareState(sq?.state, sq?.tenders);
          if (mapped !== status) {
            status = mapped;
            await patchOrder(row.id, { status });
            await logEvent(row.id, "status_synced", { status });
          }
        } catch {
          // A Square hiccup must not hide the pickup code the user already has.
        }
      }

      return {
        ok: true,
        order_id: row.id,
        status,
        pickup_code: row.pickup_code,
        checkout_url: row.checkout_url,
        lines: renderLines(row.line_items),
        total_cents: row.total_cents,
        currency: row.currency,
      };
    }

    // -----------------------------------------------------------------------
    case "get_profile": {
      const profile = await ensureProfile(authUserId);
      const [comm, dietary] = await Promise.all([getCommunicationProfile(profile.id), getDietary(profile.id)]);

      // First run. A brand-new profile is the moment Spling is most likely to
      // be abandoned, and the people it is for are the least likely to go
      // hunting for a settings screen — so there isn't one. The assistant is
      // told to set it up in three plain questions, in whatever language the
      // person is already using, and to make every one of them skippable.
      const isNew =
        !profile.display_name &&
        profile.compose_language === "en" &&
        !comm &&
        dietary.length === 0;

      if (isNew) {
        return {
          ok: true,
          first_run: true,
          display_name: null,
          compose_language: profile.compose_language,
          receipt_language: profile.receipt_language,
          communication_mode: "none",
          caretaker_staging_enabled: false,
          dietary: [],
          setup:
            "This person has no profile yet. Do NOT send them to a settings page — there isn't one, " +
            "and that is deliberate. Set it up conversationally, in the language they are already " +
            "writing to you in, asking these three things in your own words, one at a time:\n" +
            "  1. Which language they want to order in. If they are already writing in one, offer it " +
            "     as the answer rather than asking them to name it.\n" +
            "  2. Any allergies or dietary needs. Ask plainly — 'anything you need me to avoid?' — " +
            "     and if they describe something severe, record it with severity 'anaphylaxis' so it " +
            "     becomes a hard block.\n" +
            "  3. Whether speaking at counters is difficult for them, in any way. Ask it kindly and " +
            "     only once. If yes, set communication_mode. If they would rather not say, move on " +
            "     and never ask again.\n" +
            "Every question is skippable and the profile works partially filled. Save answers with " +
            "update_profile as they come, not in one batch at the end, so nothing is lost if they " +
            "stop halfway. Then carry on with whatever they originally asked for.",
        };
      }

      // The calibration is offered, never imposed. It is only worth suggesting
      // to someone for whom the spoken channel is actually difficult, and even
      // then only once — see lexicon.ts CALIBRATION_INSTRUCTIONS, which travel
      // with the words because they matter more than the words do.
      const cal = await getCalibration(profile.id).catch(() => null);
      const done = new Set(cal?.sets_done ?? []);
      const remaining = CALIBRATION.filter((set) => !done.has(set.key));
      const speechAffected = ["speech_difference", "nonverbal", "aac_user"]
        .includes(comm?.communication_mode ?? "none");

      return {
        ok: true,
        first_run: false,
        display_name: profile.display_name,
        compose_language: profile.compose_language,
        receipt_language: profile.receipt_language,
        communication_mode: comm?.communication_mode ?? "none",
        caretaker_staging_enabled: comm?.caretaker_staging_enabled ?? false,
        dietary,
        // Set when this person's assistant loses negation words. Never fixed by
        // substitution: a dropped "no" is not a wrong order, it is the thing
        // they cannot eat, so the answer is to confirm out loud instead.
        confirm_dietary_aloud: (cal?.negation_unreliable ?? []).length > 0,
        ...(speechAffected && remaining.length
          ? {
              calibration: {
                remaining_sets: remaining,
                instructions: CALIBRATION_INSTRUCTIONS,
                offer:
                  "This person has told us the spoken channel is difficult. You may offer — once, and " +
                  "only if the moment is right — to spend two minutes teaching Spling how their voice " +
                  "comes through to you, so it stops mishearing the same words. If they decline or " +
                  "ignore it, drop it permanently. Read one set at a time, ask them to say each word, " +
                  "and send back what you transcribed via update_profile.calibration_responses. Follow " +
                  "every instruction above exactly.",
              },
            }
          : {}),
        note:
          "Apply these without asking the user to restate them. Anaphylaxis-severity entries are enforced " +
          "by compose_order and cannot be overridden. Never ask again for something already recorded here." +
          ((cal?.negation_unreliable ?? []).length
            ? " This person's negation words do not transcribe reliably: confirm anything they ask to be " +
              "left out, every time, in writing."
            : ""),
      };
    }

    // -----------------------------------------------------------------------
    case "update_profile": {
      const profile = await ensureProfile(authUserId);

      const patch: Record<string, unknown> = {};
      for (const k of ["compose_language", "receipt_language", "display_name"]) {
        if (args[k] !== undefined) patch[k] = args[k];
      }
      if (Object.keys(patch).length) await updateProfile(profile.id, patch);

      const commPatch: Record<string, unknown> = {};
      if (args.communication_mode !== undefined) commPatch.communication_mode = args.communication_mode;
      if (args.caretaker_staging_enabled !== undefined) commPatch.caretaker_staging_enabled = args.caretaker_staging_enabled;
      if (Object.keys(commPatch).length) await upsertCommunicationProfile(profile.id, commPatch);

      for (const d of (args.add_dietary ?? []) as any[]) await addDietary(profile.id, d);
      for (const v of (args.remove_dietary ?? []) as string[]) await removeDietary(profile.id, v);

      // Calibration answers. Only mismatches become pairs — there is nothing to
      // learn from being understood — and negation never becomes a pair at all,
      // it becomes a standing instruction to confirm dietary out loud.
      let learned = 0;
      const responses = (args.calibration_responses ?? []) as CalibrationResponse[];
      if (Array.isArray(responses) && responses.length) {
        const { entries, negation_unreliable } = pairsFromCalibration(responses);
        if (entries.length) {
          const existing = (await getLexicon(profile.id).catch(() => [])) as LexiconEntry[];
          const merged = mergeEntries(existing, entries);
          await putLexicon(profile.id, merged);
          learned = entries.length;
        }
        const prior = await getCalibration(profile.id).catch(() => null);
        const sets = new Set([...(prior?.sets_done ?? []), ...((args.calibration_sets_done ?? []) as string[])]);
        await upsertCalibration(profile.id, {
          sets_done: [...sets],
          negation_unreliable: [...new Set([...(prior?.negation_unreliable ?? []), ...negation_unreliable])],
        });
      }

      const [comm, dietary] = await Promise.all([getCommunicationProfile(profile.id), getDietary(profile.id)]);
      return {
        ok: true,
        updated: [...Object.keys(patch), ...Object.keys(commPatch)],
        dietary,
        communication_mode: comm?.communication_mode ?? "none",
        ...(responses.length
          ? {
              calibration_saved: true,
              // Deliberately a count and nothing else. Never report which words
              // were misheard, and never say it back to the person: storing it
              // is necessary, showing it is a mirror they did not ask for.
              pairs_learned: learned,
              say_to_user:
                "Tell them it is saved and that it will get their words right from now on. Do not read " +
                "back which words were misheard, do not give a score, and do not offer to redo it.",
            }
          : {}),
      };
    }

    // -----------------------------------------------------------------------
    case "get_history": {
      const profile = await ensureProfile(authUserId);
      const limit = Math.min(50, Math.max(1, Number(args.limit ?? 20)));
      const rows = await listHistory(profile.id, limit);

      const counts = new Map<string, number>();
      for (const o of rows) {
        for (const li of o.line_items ?? []) {
          const label = renderLines([li])[0];
          counts.set(label, (counts.get(label) ?? 0) + 1);
        }
      }
      const usual = [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5)
        .map(([item, times]) => ({ item, times }));

      return {
        ok: true,
        usual,
        orders: rows.map((o) => ({
          order_id: o.id,
          status: o.status,
          when: o.created_at,
          lines: renderLines(o.line_items ?? []),
          total_cents: o.total_cents,
          currency: o.currency,
          pickup_code: o.pickup_code,
        })),
      };
    }

    // -----------------------------------------------------------------------
    case "submit_correction": {
      const profile = await ensureProfile(authUserId);
      const row = await getOrderRow(String(args.order_id ?? ""), profile.id);
      if (!row) return { ok: false, error: "order_not_found" };

      // Pin the complaint to the line item and modifier that actually failed.
      // An unattributed correction still gets recorded; it is simply worth less
      // later, and we would rather store that honestly than guess a link.
      let shaped;
      try {
        shaped = shapeCorrection(
          {
            kind: String(args.kind),
            item_name: args.item_name as string,
            received: args.received as string,
            note: args.note as string,
          },
          row.line_items,
        );
      } catch (e) {
        if (e instanceof InvalidCorrection) return { ok: false, error: "invalid_correction", message: e.message };
        throw e;
      }

      await addCorrection({
        order_id: row.id,
        profile_id: profile.id,
        merchant_id: row.merchant_id,
        ordered: row.line_items,
        ...shaped,
      });
      await logEvent(row.id, "correction_filed", {
        kind: shaped.kind,
        item_name: shaped.item_name,
        modifier_name: shaped.modifier_name,
        attributed: shaped.line_item_index !== null,
      });

      const acc = await merchantAccuracy(row.merchant_id).catch(() => null);
      return {
        ok: true,
        message: shaped.line_item_index === null
          ? "Recorded against this merchant. It was not tied to a specific item, so tell us which one if you can — that is what makes the record useful later."
          : `Recorded against ${shaped.item_name}${shaped.modifier_name ? ` (${shaped.modifier_name})` : ""} at this location.`,
        attributed_to: {
          item: shaped.item_name,
          modifier: shaped.modifier_name,
          line_item_index: shaped.line_item_index,
        },
        merchant_accuracy: acc?.[0] ?? null,
      };
    }

    // -----------------------------------------------------------------------
    case "export_profile": {
      const profile = await ensureProfile(authUserId);
      const [communication, dietary, history] = await Promise.all([
        getCommunicationProfile(profile.id),
        getDietary(profile.id),
        listHistory(profile.id, 200),
      ]);
      return { ok: true, pam: toPam({ profile, communication, dietary, history }) };
    }

    default:
      throw new Error(`unknown tool: ${name}`);
  }
}

// ---------------------------------------------------------------------------
// MCP JSON-RPC over Streamable HTTP
// ---------------------------------------------------------------------------

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, mcp-session-id, mcp-protocol-version",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

function rpcResult(id: unknown, result: unknown) { return { jsonrpc: "2.0", id, result }; }
function rpcError(id: unknown, code: number, message: string) { return { jsonrpc: "2.0", id, error: { code, message } }; }

/** Never leak internals to the model — it will repeat them to the user. */
function safeMessage(e: unknown): string {
  if (e instanceof SquareError) return "The merchant's system rejected that request. The order was not placed.";
  const m = e instanceof Error ? e.message : String(e);
  return m.length > 200 ? "That request could not be completed." : m;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });

  // Discovery, registration, consent, token and revoke are all unauthenticated
  // by definition — they are how a caller becomes authenticated.
  const oauth = await handleOAuth(req);
  if (oauth) return oauth;

  const auth = req.headers.get("authorization") ?? "";
  const viaOAuth = await subjectFromAccessToken(req);
  const viaBearer = SPLING_BEARER.length > 0 && auth === `Bearer ${SPLING_BEARER}`;

  if (!viaOAuth && !viaBearer) {
    // The WWW-Authenticate header is what turns "paste a token" into "sign in":
    // it tells the assistant where the authorization server lives, so it can
    // walk the user through a login instead of asking a human for a secret.
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { ...CORS, "Content-Type": "application/json", "WWW-Authenticate": wwwAuthenticate(issuerFrom(req)) },
    });
  }

  const headers = { "Content-Type": "application/json", ...CORS };

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ ok: true, server: "spling-mcp", version: SERVER_VERSION, tools: TOOLS.length }),
      { headers },
    );
  }

  let msg: any;
  try { msg = await req.json(); }
  catch { return new Response(JSON.stringify(rpcError(null, -32700, "parse error")), { status: 400, headers }); }

  const { id, method, params } = msg ?? {};

  try {
    switch (method) {
      case "initialize":
        return new Response(JSON.stringify(rpcResult(id, {
          protocolVersion: params?.protocolVersion ?? "2025-06-18",
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "spling", version: SERVER_VERSION },
          instructions:
            "Spling places food orders as validated structured data, so the user never has to speak at the " +
            "point of sale. Call get_profile first to pick up their language and allergens. Call get_catalog " +
            "before composing. compose_order resolves candidate items against the live catalog and rejects " +
            "anything it cannot match exactly — when it rejects, ask the user, never substitute. " +
            "If get_profile returns first_run, follow its setup instructions conversationally before " +
            "anything else: this product exists for people who should never have to fill in a form.",
        })), { headers });

      case "notifications/initialized":
        return new Response(null, { status: 202, headers });

      case "tools/list":
        return new Response(JSON.stringify(rpcResult(id, { tools: TOOLS })), { headers });

      case "tools/call": {
        const name = params?.name as string;
        const args = (params?.arguments ?? {}) as Record<string, unknown>;
        if (!TOOLS.some((t) => t.name === name)) {
          return new Response(JSON.stringify(rpcError(id, -32602, `unknown tool: ${name}`)), { status: 400, headers });
        }
        try {
          const out = await callTool(name, args, req);
          const isError = typeof out === "object" && out !== null && (out as any).ok === false;
          return new Response(JSON.stringify(rpcResult(id, {
            content: [{ type: "text", text: JSON.stringify(out, null, 2) }],
            isError,
          })), { headers });
        } catch (e) {
          return new Response(JSON.stringify(rpcResult(id, {
            content: [{ type: "text", text: JSON.stringify({ ok: false, error: safeMessage(e) }, null, 2) }],
            isError: true,
          })), { headers });
        }
      }

      case "ping":
        return new Response(JSON.stringify(rpcResult(id, {})), { headers });

      default:
        return new Response(JSON.stringify(rpcError(id, -32601, `method not found: ${method}`)), { status: 404, headers });
    }
  } catch (e) {
    return new Response(JSON.stringify(rpcError(id, -32000, safeMessage(e))), { status: 500, headers });
  }
});

// ---------------------------------------------------------------------------
// AUTH NOTE.
//
// subjectFrom() tries OAuth first and falls back to SPLING_BEARER. The bearer
// authenticates the CALLER, not a person: every request carrying it resolves to
// the same subject, so two people sharing one would share one profile —
// including one person's allergens. Keep it for local development. Do not set
// it in an environment real people can reach.
//
// The OAuth path resolves a person: identity.ts delegates sign-in to Google,
// Apple or an email link, and the subject is their Supabase user id, stable
// across devices and across re-authorising. Every store.ts call is keyed by
// that subject, which is why adding identity was one function and not a
// rewrite.
// ---------------------------------------------------------------------------
