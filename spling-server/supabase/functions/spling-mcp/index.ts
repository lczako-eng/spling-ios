// Spling MCP Server — Phase 1 complete (get_menu), Phases 2-5 stubbed.
// Deploy: supabase functions deploy spling-mcp --no-verify-jwt
// Secrets: supabase secrets set SQUARE_ACCESS_TOKEN=... SQUARE_ENV=sandbox SPLING_BEARER=...
//
// Transport: MCP Streamable HTTP (POST JSON-RPC 2.0).
// Phase 1 auth: shared bearer token (Claude custom connector supports this).
// Phase 2+: replace with OAuth 2.1 + Dynamic Client Registration for ChatGPT.

const SQUARE_ENV = Deno.env.get("SQUARE_ENV") ?? "sandbox";
const SQUARE_BASE = SQUARE_ENV === "production"
  ? "https://connect.squareup.com"
  : "https://connect.squareupsandbox.com";
const SQUARE_TOKEN = Deno.env.get("SQUARE_ACCESS_TOKEN") ?? "";
const SPLING_BEARER = Deno.env.get("SPLING_BEARER") ?? "";
const SQUARE_VERSION = "2026-07-16"; // pin; update deliberately

// ---------- Menu cache (15 min max — never serve stale prices) ----------
type CachedMenu = { at: number; menu: unknown };
const menuCache = new Map<string, CachedMenu>();
const MENU_TTL_MS = 15 * 60 * 1000;

// ---------- Square helpers ----------
async function square(path: string, init: RequestInit = {}): Promise<any> {
  const res = await fetch(`${SQUARE_BASE}${path}`, {
    ...init,
    headers: {
      "Authorization": `Bearer ${SQUARE_TOKEN}`,
      "Square-Version": SQUARE_VERSION,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(`square ${path} ${res.status}: ${JSON.stringify(body.errors ?? body)}`);
  }
  return body;
}

async function fetchMenu(locationId: string) {
  const cached = menuCache.get(locationId);
  if (cached && Date.now() - cached.at < MENU_TTL_MS) return cached.menu;

  // Catalog: items + modifier lists + categories in one search
  const data = await square(`/v2/catalog/list?types=ITEM,MODIFIER_LIST,CATEGORY`);
  const objects: any[] = data.objects ?? [];

  const categories = new Map<string, string>();
  for (const o of objects.filter(o => o.type === "CATEGORY")) {
    categories.set(o.id, o.category_data?.name ?? "Other");
  }
  const modifierLists = new Map<string, any>();
  for (const o of objects.filter(o => o.type === "MODIFIER_LIST")) {
    modifierLists.set(o.id, {
      id: o.id,
      name: o.modifier_list_data?.name,
      modifiers: (o.modifier_list_data?.modifiers ?? []).map((m: any) => ({
        id: m.id,
        name: m.modifier_data?.name,
        price_cents: Number(m.modifier_data?.price_money?.amount ?? 0),
      })),
    });
  }

  const items = objects.filter(o => o.type === "ITEM").map((o: any) => {
    const d = o.item_data ?? {};
    const variations = (d.variations ?? []).map((v: any) => ({
      id: v.id,
      name: v.item_variation_data?.name ?? "Regular",
      price_cents: Number(v.item_variation_data?.price_money?.amount ?? 0),
      currency: v.item_variation_data?.price_money?.currency ?? "CAD",
    }));
    const mods = (d.modifier_list_info ?? [])
      .map((mi: any) => modifierLists.get(mi.modifier_list_id))
      .filter(Boolean);
    return {
      id: o.id,
      name: d.name,
      description: d.description ?? null,
      category: categories.get(d.category_id) ?? "Menu",
      variations,
      modifier_lists: mods,
    };
  });

  const menu = { location_id: locationId, fetched_at: new Date().toISOString(), items };
  menuCache.set(locationId, { at: Date.now(), menu });
  return menu;
}

// ---------- Tool definitions ----------
const TOOLS = [
  {
    name: "get_menu",
    description:
      "Get the live menu for a merchant location: items, exact prices in cents, and the valid " +
      "modifiers for each item. Always call this before composing an order — orders may only " +
      "contain items and modifiers that appear in this menu.",
    inputSchema: {
      type: "object",
      properties: {
        location_id: {
          type: "string",
          description: "Square location ID. Omit to use the default/demo location.",
        },
      },
    },
  },
  { name: "compose_order",     description: "Phase 2. Validate a proposed order against the live menu.", inputSchema: { type: "object", properties: {} } },
  { name: "place_order",       description: "Phase 2. Submit a composed order and return a payment link.", inputSchema: { type: "object", properties: {} } },
  { name: "get_order_status",  description: "Phase 2. Check status and pickup code for an order.", inputSchema: { type: "object", properties: {} } },
  { name: "get_profile",       description: "Phase 3. Read the user's language and communication profile.", inputSchema: { type: "object", properties: {} } },
  { name: "update_profile",    description: "Phase 3. Update language, dietary, or communication settings.", inputSchema: { type: "object", properties: {} } },
  { name: "get_history",       description: "Phase 3. The user's past orders ('the usual').", inputSchema: { type: "object", properties: {} } },
  { name: "submit_correction", description: "Phase 5. Record ordered-vs-received for the accuracy ledger.", inputSchema: { type: "object", properties: {} } },
  { name: "export_profile",    description: "Phase 4. Export the profile in PAM (Portable AI Memory) JSON.", inputSchema: { type: "object", properties: {} } },
];

const IMPLEMENTED = new Set(["get_menu"]);

async function callTool(name: string, args: Record<string, unknown>) {
  if (!IMPLEMENTED.has(name)) {
    return { error: "not_implemented", tool: name, note: "Stubbed — later phase." };
  }
  switch (name) {
    case "get_menu": {
      let locationId = (args.location_id as string) ?? "";
      if (!locationId) {
        const locs = await square("/v2/locations");
        locationId = locs.locations?.[0]?.id ?? "";
        if (!locationId) throw new Error("No Square locations found on this account.");
      }
      return await fetchMenu(locationId);
    }
    default:
      throw new Error(`unknown tool: ${name}`);
  }
}

// ---------- MCP JSON-RPC over Streamable HTTP ----------
function rpcResult(id: unknown, result: unknown) {
  return { jsonrpc: "2.0", id, result };
}
function rpcError(id: unknown, code: number, message: string) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

Deno.serve(async (req) => {
  // CORS for connector handshakes
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, content-type, mcp-session-id",
        "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
      },
    });
  }

  // Phase 1 auth: shared bearer. (OAuth 2.1 + DCR replaces this in Phase 2.)
  const auth = req.headers.get("authorization") ?? "";
  if (!SPLING_BEARER || auth !== `Bearer ${SPLING_BEARER}`) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  if (req.method !== "POST") {
    return Response.json({ ok: true, server: "spling-mcp", phase: 1 });
  }

  let msg: any;
  try { msg = await req.json(); } catch {
    return Response.json(rpcError(null, -32700, "parse error"), { status: 400 });
  }

  const { id, method, params } = msg;
  const headers = { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" };

  try {
    switch (method) {
      case "initialize":
        return new Response(JSON.stringify(rpcResult(id, {
          protocolVersion: params?.protocolVersion ?? "2025-06-18",
          capabilities: { tools: {} },
          serverInfo: { name: "spling", version: "0.1.0" },
        })), { headers });

      case "notifications/initialized":
        return new Response(null, { status: 202, headers });

      case "tools/list":
        return new Response(JSON.stringify(rpcResult(id, { tools: TOOLS })), { headers });

      case "tools/call": {
        const name = params?.name as string;
        const args = (params?.arguments ?? {}) as Record<string, unknown>;
        const out = await callTool(name, args);
        return new Response(JSON.stringify(rpcResult(id, {
          content: [{ type: "text", text: JSON.stringify(out, null, 2) }],
        })), { headers });
      }

      case "ping":
        return new Response(JSON.stringify(rpcResult(id, {})), { headers });

      default:
        return new Response(JSON.stringify(rpcError(id, -32601, `method not found: ${method}`)),
          { status: 404, headers });
    }
  } catch (e) {
    return new Response(JSON.stringify(rpcError(id, -32000, String(e?.message ?? e))),
      { status: 500, headers });
  }
});
