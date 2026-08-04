# Spling

Your AI assistant is your mouth. Order without speaking — in any language, with any voice,
or with no voice at all.

An MCP server that lets Claude, ChatGPT, and any assistant speaking the protocol place
validated, structured food orders on a user's behalf via Square — carrying the user's
language and communication profile so the spoken channel is never required at the point
of sale.

## Status

All nine tools are implemented, across two rails. The composition engine — the part that
must never be wrong — is covered by 59 tests that run with no network, no database and no
install step.

The engine is domain-neutral: the same code validates a café order, a hotel booking, a
pharmacy request and a clinic appointment. `compose_domains_test.ts` proves it, and fails
if a food-shaped assumption is reintroduced.

**Not yet verified against real money.** The phase gates in `CLAUDE.md` require ten
consecutive sandbox orders (Phase 2) and ten consecutive non-English orders (Phase 3)
against a live Square sandbox. That needs credentials this code has never had. Until
then, treat the Square-facing paths as written-but-unproven.

## Quick start

1. Read `CLAUDE.md` (build rules) and `docs/BUILD_PLAN.md` (the week, day by day)
2. Square Developer app → sandbox access token
3. New Supabase project → `supabase link` → `supabase db push`
4. Set the secrets:
   ```bash
   supabase secrets set \
     SQUARE_ACCESS_TOKEN=<sandbox token> \
     SQUARE_ENV=sandbox \
     SPLING_BEARER=$(openssl rand -hex 32) \
     SUPABASE_URL=<project url> \
     SUPABASE_SERVICE_ROLE_KEY=<service role key>
   ```
5. `supabase functions deploy spling-mcp --no-verify-jwt`
6. Add to Claude as a custom connector (function URL + bearer)

Verify the deployment answers:

```bash
curl -sX POST "$FN_URL" \
  -H "Authorization: Bearer $SPLING_BEARER" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq '.result.tools | length'
# → 9
```

## Tests

```bash
./test.sh
```

No network, no database, no dependencies. Runs under Node 22+ via type-stripping; the
same files run under `deno test`.

- **`compose_test.ts` (20)** — the validator. Resolution, ambiguity refusal, cross-item
  modifier rejection, quantity bounds, integer-cent arithmetic, diacritic matching for
  cross-language input, and the full dietary ladder including the guarantee that an
  anaphylaxis block cannot be overridden even when a caller explicitly asks.
- **`protocol_test.ts` (10)** — the wiring. Square catalog mapping, the order payload
  (which must carry catalog IDs and never human strings), quantity typing, order-state
  mapping, PAM export shape, the nine-tool surface, and a check that no secret is
  hard-coded.

## How an order flows

```
assistant                    spling-mcp                         Square
   │                             │                                │
   │ get_profile ───────────────▶│  language + allergens          │
   │ get_menu ──────────────────▶│───── catalog/list ────────────▶│
   │                             │◀──── items, modifiers ─────────│
   │ compose_order ─────────────▶│  compose.ts validates          │
   │   (candidates, any lang)    │  → exact IDs, or rejection     │
   │◀─── priced draft ───────────│  (nothing persists on failure) │
   │ place_order ───────────────▶│───── POST /v2/orders ─────────▶│
   │                             │───── payment-links ───────────▶│
   │◀─── checkout URL + code ────│                                │
```

The model proposes; the validator disposes. Nothing reaches a merchant that
`compose.ts` has not resolved to exact catalog IDs.

## Repo map

- `CLAUDE.md` — rules Claude Code follows
- `supabase/functions/spling-mcp/`
  - `index.ts` — MCP server: JSON-RPC envelope, auth, the nine tools
  - `compose.ts` — **the composition engine.** Pure, no I/O. The moat.
  - `square.ts` — the POS rail as a provider: catalog → catalogue, orders, payment links
  - `store.ts` — Postgres persistence; strips health-adjacent fields from the audit log
  - `pam.ts` — Portable AI Memory export
  - `*_test.ts` — the suites above
- `supabase/migrations/`
  - `001_init.sql` — core schema, RLS everywhere
  - `002_accuracy_intelligence.sql` — the five questions, answerable
  - `003_offerings.sql` — catalogues for businesses without a POS
- `docs/BUILD_PLAN.md` — 7 days, 7 checkpoints
- `docs/WEBSITE_BRIEF.md` — spling.org direction

## Before real users

The shared bearer authenticates the *caller*, not a person — every request resolves to
one subject. That is correct for a single-tenant sandbox and wrong for anything else,
since profiles are per-person by definition.

OAuth 2.1 + Dynamic Client Registration is a hard ChatGPT requirement. Every persistence
call is already keyed by a subject id, so switching over is a change to `subjectFrom()`
in `index.ts` — deliberately one function, so the migration is not a rewrite.

© 2026 R-evolv Inc.
