# Spling — Claude Code Project Instructions

## What this is
Spling is an MCP (Model Context Protocol) server that lets AI assistants (Claude, ChatGPT)
place food orders on behalf of a specific person — in their own language, with their
communication profile applied — delivering validated structured line items to the merchant's
POS via Square. The user never speaks at the point of sale.

**The thesis: the assistant is the user's mouth.**

## Architecture (do not deviate)
- **Runtime:** Supabase Edge Functions (Deno / TypeScript). No Node servers.
- **Transport:** Streamable HTTP MCP at `/spling-mcp`. Remote HTTPS only.
- **Merchant rail:** Square API (sandbox first). NEVER scrape menus. NEVER cache prices > 15 min.
- **Payments:** Square Checkout links only. We NEVER touch card data. PCI scope stays zero.
- **DB:** Supabase Postgres with RLS on every table. No exceptions.
- **Composition rule (Pulse Engine pattern):** The LLM maps intent → candidate items.
  Deterministic code validates every item, modifier, and quantity against the live Square
  catalog and REJECTS anything invalid. The LLM never emits free text into an order.
  All decisions are logged to `order_events` for a full audit trail.

## Hard rules
1. One task at a time. Complete, verify, then move to the next. Never batch unverified changes.
2. Every DB table gets RLS policies in the same migration that creates it.
3. `communication_profile` data is health-adjacent (PIPEDA). It is never logged, never sent
   to Square, never included in error messages. It informs composition only.
4. Secrets live in Supabase secrets (`supabase secrets set`). Never in code, never in git.
5. Do not build ahead of the current phase. Stubs for future tools return
   `{ error: "not_implemented", phase: N }`.
6. All money is integer cents. Never floats.

## Phase gates (build in this order)
- **Phase 1 — get_menu.** MCP server + `get_menu` against Square sandbox catalog.
  DONE = Claude connects as custom connector and returns a real menu.
- **Phase 2 — order lands.** `compose_order`, `place_order`, Square Checkout link,
  `get_order_status`. DONE = 10 consecutive sandbox orders placed and "paid."
- **Phase 3 — language.** `get_profile`/`update_profile` with language field;
  cross-language composition (user speaks any language → English line items).
  DONE = 10 consecutive non-English orders land correctly. THIS IS THE PRODUCT.
- **Phase 4 — communication profile.** Accessibility fields, allergen enforcement at
  composition, PAM-format `export_profile`.
- **Phase 5 — accuracy ledger.** `submit_correction`; received-vs-ordered records
  tied to merchant/location/item.
- **Phase 6 — website + polish.** spling.org update per docs/WEBSITE_BRIEF.md.

## Tool surface (final — 9 tools)
get_menu · compose_order · place_order · get_order_status · get_profile ·
update_profile · get_history · submit_correction · export_profile

## Key files
- `supabase/functions/spling-mcp/index.ts` — the MCP server (Phase 1 version is complete; extend it)
- `supabase/migrations/001_init.sql` — full schema for all phases (already written; apply as-is)
- `docs/BUILD_PLAN.md` — day-by-day plan for the week
- `docs/WEBSITE_BRIEF.md` — spling.org redesign direction
- `.env.example` — required secrets

## Environment
- Square Sandbox: create app at developer.squareup.com → use SANDBOX access token.
- Supabase: new project (do NOT reuse the Rooted project).
- Deploy: `supabase functions deploy spling-mcp --no-verify-jwt`
  (MCP handles its own auth; Phase 1 uses a shared bearer token, Phase 2+ adds OAuth 2.1 + DCR
  for ChatGPT compatibility).

## Testing an order end-to-end (Phase 2)
Square sandbox test values: card 4111 1111 1111 1111, any future expiry, CVV 111.
Checkout links in sandbox render a test payment page — complete it and verify the
order status transitions in `orders` and Square's sandbox dashboard.

## What Spling is NOT (refuse scope drift)
- Not a reservation system (integrate existing MCP servers later, never build)
- Not a general memory product (export PAM; don't compete with Mem0/Supermemory)
- Not a payment rail. Not merchant-side voice AI. Not NFC (deferred indefinitely).
