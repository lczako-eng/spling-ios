// ============================================================================
// Spling MCP Server — the connector.
//
// Deploy:  supabase functions deploy spling-mcp --no-verify-jwt
// Secrets: supabase secrets set SQUARE_ACCESS_TOKEN=... SQUARE_ENV=sandbox \
//            SPLING_BEARER=... SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=...
//
// Transport: MCP Streamable HTTP (POST JSON-RPC 2.0). Remote HTTPS only —
// ChatGPT does not accept stdio servers, so a hosted endpoint is mandatory.
//
// Auth: shared bearer today. OAuth 2.1 + Dynamic Client Registration is
// required before the ChatGPT path opens; see AUTH NOTE at the bottom.
//
// The rule this whole file exists to enforce: the model proposes, the
// validator disposes. Nothing reaches a merchant that compose.ts has not
// resolved to exact catalog IDs.
// ============================================================================

import { compose, pickupCode, renderLines, type RequestedItem } from "./compose.ts";
import {
  createOrder, createPaymentLink, defaultLocationId, fetchMenu,
  getOrder, mapSquareState, SquareError,
} from "./square.ts";
import {
  addCorrection, addDietary, createDraftOrder, ensureMerchant, ensureProfile,
  getCommunicationProfile, getDietary, getOrderRow, listHistory, logEvent,
  merchantAccuracy, patchOrder, removeDietary, updateProfile,
  upsertCommunicationProfile,
} from "./store.ts";
import { toPam } from "./pam.ts";

const SPLING_BEARER = Deno.env.get("SPLING_BEARER") ?? "";
const SERVER_VERSION = "0.5.0";

// ---------------------------------------------------------------------------
// Tool surface — the nine tools, final.
// Descriptions are written for the model: they say what a tool guarantees, so
// the assistant stops trying to be clever about menus it has not fetched.
// ---------------------------------------------------------------------------
const TOOLS = [
  {
    name: "get_menu",
    description:
      "Get the live menu for a merchant location: items, exact prices in cents, and the valid " +
      "modifiers for each item. Always call this before composing an order. Orders may only " +
      "contain items and modifiers that appear here.",
    inputSchema: {
      type: "object",
      properties: {
        location_id: { type: "string", description: "Square location ID. Omit for the default location." },
      },
    },
  },
  {
    name: "compose_order",
    description:
      "Validate a proposed order against the live menu and price it. Accepts items in ANY language — " +
      "resolve what the user meant into candidate names, and this tool will match them to exact catalog " +
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
              name_or_id: { type: "string", description: "Item name or Square catalog ID." },
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
      "Submit a composed order to the merchant's point of sale and return a secure Square checkout link " +
      "plus a pickup code. Spling never handles card data. Call only after compose_order returned ok.",
    inputSchema: {
      type: "object",
      required: ["order_id"],
      properties: { order_id: { type: "string" }, location_id: { type: "string" } },
    },
  },
  {
    name: "get_order_status",
    description: "Current status, pickup code and checkout link for one order. Reads live state from Square.",
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

async function resolveLocation(args: Record<string, unknown>): Promise<string> {
  return (args.location_id as string) || await defaultLocationId();
}

/** The authenticated subject. With the shared bearer this is a single tenant. */
function subjectFrom(_req: Request): string {
  return Deno.env.get("SPLING_DEFAULT_SUBJECT") ?? "00000000-0000-0000-0000-000000000001";
}

// ---------------------------------------------------------------------------
// tools
// ---------------------------------------------------------------------------

async function callTool(name: string, args: Record<string, unknown>, req: Request): Promise<unknown> {
  const authUserId = subjectFrom(req);

  switch (name) {
    // -----------------------------------------------------------------------
    case "get_menu": {
      const locationId = await resolveLocation(args);
      const menu = await fetchMenu(locationId);
      return {
        location_id: menu.location_id,
        fetched_at: menu.fetched_at,
        note: "Prices are integer cents. Only these items and modifiers may be ordered.",
        items: menu.items.map((i) => ({
          id: i.id,
          name: i.name,
          category: i.category,
          description: i.description,
          variations: i.variations.map((v) => ({ id: v.id, name: v.name, price_cents: v.price_cents, currency: v.currency })),
          modifiers: i.modifier_lists.flatMap((l) => l.modifiers.map((m) => ({ id: m.id, name: m.name, price_cents: m.price_cents }))),
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
      const menu = await fetchMenu(locationId);

      const result = compose({
        menu,
        requested,
        dietary,
        overrides: (args.overrides ?? []) as string[],
      });

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
          message: `Order is ${row.status}; only a composed order can be placed.`,
        };
      }

      const locationId = await resolveLocation(args);
      const code = pickupCode();

      const sq = await createOrder(locationId, row.line_items, idem(), code);
      await logEvent(row.id, "square_order_created", { square_order_id: sq.id, total_cents: sq.total_cents });

      // Square is the source of truth for money. If our arithmetic and theirs
      // disagree, we stop rather than charge a number we did not calculate.
      if (sq.total_cents !== row.total_cents) {
        await patchOrder(row.id, { status: "failed", square_order_id: sq.id });
        await logEvent(row.id, "total_mismatch", { ours: row.total_cents, square: sq.total_cents });
        return {
          ok: false,
          error: "total_mismatch",
          message: "The merchant's price changed since this order was composed. Compose it again.",
          ours_cents: row.total_cents,
          merchant_cents: sq.total_cents,
        };
      }

      const link = await createPaymentLink(sq.id, idem(), `Spling pickup ${code}`);
      const updated = await patchOrder(row.id, {
        square_order_id: sq.id,
        checkout_url: link.url,
        pickup_code: code,
        status: "payment_pending",
      });
      await logEvent(row.id, "payment_link_created", { pickup_code: code });

      return {
        ok: true,
        order_id: updated.id,
        pickup_code: code,
        checkout_url: link.url,
        total_cents: updated.total_cents,
        currency: updated.currency,
        lines: renderLines(row.line_items),
        next: "Give the user the checkout link and the pickup code. Spling never sees card details.",
      };
    }

    // -----------------------------------------------------------------------
    case "get_order_status": {
      const profile = await ensureProfile(authUserId);
      const row = await getOrderRow(String(args.order_id ?? ""), profile.id);
      if (!row) return { ok: false, error: "order_not_found" };

      let status = row.status;
      if (row.square_order_id) {
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
      return {
        ok: true,
        display_name: profile.display_name,
        compose_language: profile.compose_language,
        receipt_language: profile.receipt_language,
        communication_mode: comm?.communication_mode ?? "none",
        caretaker_staging_enabled: comm?.caretaker_staging_enabled ?? false,
        dietary,
        note:
          "Apply these without asking the user to restate them. Anaphylaxis-severity entries are enforced " +
          "by compose_order and cannot be overridden.",
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

      const [comm, dietary] = await Promise.all([getCommunicationProfile(profile.id), getDietary(profile.id)]);
      return {
        ok: true,
        updated: [...Object.keys(patch), ...Object.keys(commPatch)],
        dietary,
        communication_mode: comm?.communication_mode ?? "none",
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

      await addCorrection({
        order_id: row.id,
        profile_id: profile.id,
        merchant_id: row.merchant_id,
        item_name: (args.item_name as string) ?? null,
        kind: String(args.kind),
        ordered: row.line_items,
        received: args.received ?? null,
        note: (args.note as string) ?? null,
      });
      await logEvent(row.id, "correction_filed", { kind: args.kind, item_name: args.item_name ?? null });

      const accuracy = await merchantAccuracy(row.merchant_id).catch(() => null);
      return {
        ok: true,
        message: "Recorded against this merchant and item.",
        merchant_accuracy: accuracy?.[0] ?? null,
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

  const auth = req.headers.get("authorization") ?? "";
  if (!SPLING_BEARER || auth !== `Bearer ${SPLING_BEARER}`) {
    return Response.json({ error: "unauthorized" }, { status: 401, headers: CORS });
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
            "point of sale. Call get_profile first to pick up their language and allergens. Call get_menu " +
            "before composing. compose_order resolves candidate items against the live catalog and rejects " +
            "anything it cannot match exactly — when it rejects, ask the user, never substitute.",
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
// AUTH NOTE — read before opening the ChatGPT path.
//
// The shared bearer above authenticates the CALLER, not a person: every request
// resolves to one subject. That is correct for a single-tenant sandbox and
// wrong for anything else, because profiles are per-person by definition.
//
// Before real users: OAuth 2.1 + Dynamic Client Registration (a hard ChatGPT
// requirement, not a preference), with subjectFrom() returning the verified
// `sub` claim. Every store.ts call is already keyed by that subject, so this is
// a swap of one function — deliberately, so the migration is not a rewrite.
// ---------------------------------------------------------------------------
