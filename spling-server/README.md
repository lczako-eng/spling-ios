# Spling

Your AI assistant is your mouth. Be understood by any business — in any language, with any
voice, or with no voice at all.

An MCP server that lets Claude, ChatGPT, and any assistant speaking the protocol compose a
**validated structured transaction** on a user's behalf — carrying their language and
communication profile so speech is never required at the counter.

Ordering is the first application. The communication layer is the product; see
`docs/STRATEGY.md`, which outranks this file on questions of direction.

## Status

All nine tools are implemented, across two rails. The composition engine — the part that
must never be wrong — is covered by 96 tests that run with no network, no database and no
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
4. Supabase dashboard → **Authentication → Providers**: enable Google and Apple, and
   leave email enabled. Then **URL Configuration → Redirect URLs**: add
   `<function url>/auth/callback`. Supabase refuses to redirect anywhere not on that
   list, which is what stops the sign-in flow being pointed at someone else's server.
5. Set the secrets:
   ```bash
   supabase secrets set \
     SQUARE_ACCESS_TOKEN=<sandbox token> \
     SQUARE_ENV=sandbox \
     SUPABASE_URL=<project url> \
     SUPABASE_ANON_KEY=<anon key> \
     SUPABASE_SERVICE_ROLE_KEY=<service role key>
   ```
6. `supabase functions deploy spling-mcp --no-verify-jwt`
7. Add to Claude as a custom connector (function URL — the assistant registers itself
   and walks the user through signing in)

Verify the deployment answers. Unauthenticated, it should refuse and say where to sign in:

```bash
curl -si "$FN_URL" | grep -i www-authenticate
# → WWW-Authenticate: Bearer resource_metadata="…/.well-known/oauth-protected-resource"
```

With a local bearer set, the tool surface should be nine:

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
- **`compose_domains_test.ts` (12)** — proof the engine is not *about* food: a hotel
  booking, a free pharmacy service at zero cents, a clinic appointment blocked by a latex
  constraint, and a guard that fails if food-shaped access is reintroduced into
  `compose.ts`.
- **`ledger_test.ts` (17)** — correction attribution, refusal to guess a modifier when a
  line has two, and an accuracy figure that is never quotable below n=384.
- **`auth_test.ts` (21)** — the OAuth layer: PKCE S256 (and the refusal of `plain`),
  exact redirect matching so a prefix cannot steal a code, rejection of the grant types
  OAuth 2.1 removed, and discovery documents that advertise only what is implemented.
- **`identity_test.ts` (16)** — the sign-in layer: the provider allowlist, a callback
  that cannot be pointed elsewhere, a subject that is a real user id or an error, and
  sign-in pages that escape a client's name, work with JavaScript off, and make no
  outbound request — so nobody learns that a particular person is signing in to Spling.
- **`protocol_test.ts` (10)** — the wiring. Square catalog mapping, the order payload
  (which must carry catalog IDs and never human strings), quantity typing, order-state
  mapping, PAM export shape, the nine-tool surface, and a check that no secret is
  hard-coded.

## How an order flows

```
assistant                    spling-mcp                         Square
   │                             │                                │
   │ get_profile ───────────────▶│  language + allergens          │
   │ get_catalog ───────────────▶│───── catalog/list ────────────▶│
   │                             │◀──── items, modifiers ─────────│
   │ compose_order ─────────────▶│  compose.ts validates          │
   │   (candidates, any lang)    │  → exact IDs, or rejection     │
   │◀─── priced draft ───────────│  (nothing persists on failure) │
   │ place_order ───────────────▶│───── POST /v2/orders ─────────▶│
   │                             │───── payment-links ───────────▶│
   │◀─── checkout URL + code ────│                                │
```

The model proposes; the validator disposes. Nothing reaches a business that `compose.ts`
has not resolved to exact catalogue IDs.

A business without a point of sale follows the same path, with the directory provider in
place of Square and a reference code in place of a checkout link.

## Repo map

- `CLAUDE.md` — rules Claude Code follows
- `supabase/functions/spling-mcp/`
  - `index.ts` — MCP server: JSON-RPC envelope, auth, the nine tools
  - `catalogue.ts` — the provider-agnostic domain model, and the noun each kind of
    business uses. Offering / Variant / Option describes a coffee, a hotel room, a
    pharmacy service and an appointment equally.
  - `compose.ts` — **the composition engine.** Pure, no I/O. The moat. Validates against a
    Catalogue and never learns which rail produced it.
  - `square.ts` — the POS rail as a provider: catalog → catalogue, orders, payment links
  - `directory.ts` — the rail for businesses with no POS, reading a catalogue they publish
    into Spling (003). No payment leg, deliberately.
  - `ledger.ts` — correction attribution and honest accuracy arithmetic
  - `store.ts` — Postgres persistence; strips health-adjacent fields from the audit log
  - `auth.ts` / `oauth_routes.ts` / `oauth_store.ts` — OAuth 2.1 + DCR, so signing in is
    a button rather than a pasted secret
  - `identity.ts` — **who** that button signs in: Google, Apple, or an email link.
    Delegated to Supabase Auth; Spling keeps the user id and nothing else.
  - `pam.ts` — Portable AI Memory export
  - `*_test.ts` — the suites below
- `supabase/migrations/`
  - `001_init.sql` — core schema, RLS everywhere
  - `002_accuracy_intelligence.sql` — the five questions, answerable
  - `003_offerings.sql` — catalogues for businesses without a POS
  - `004_oauth.sql` — clients, codes and tokens (hashed at rest)
  - `005_identity.sql` — the request, parked while its owner is away signing in
- `docs/BUILD_PLAN.md` — 7 days, 7 checkpoints
- `docs/WEBSITE_BRIEF.md` — spling.org direction

## Signing in

Two separate questions, answered by two files.

**May this assistant act for someone?** — `auth.ts`. OAuth 2.1 + Dynamic Client
Registration. This exists for a usability reason before a technical one: the shared bearer
made Spling a programmer's product — to use it you opened developer settings and pasted a
64-character secret. The people this is built for will not do that, and should not have
to. OAuth replaces the paste with a button.

It is also a hard ChatGPT requirement, and the entry fee for being listed in an
assistant's connector directory — which is the only path to installation being one click.
The same change fixes the usability wall and the distribution wall.

**Who is it?** — `identity.ts`. Three ways in: **Google**, **Apple**, and an **email
link**. The third is not a footnote. The people Spling is built for include those least
likely to hold a Google or Apple account — an 85-year-old, someone in supported living on
a managed device, a newcomer three weeks into the country. A sign-in wall that only speaks
Silicon Valley would exclude exactly the users this exists for. Apple is not optional in
the other direction either: App Store review requires Sign in with Apple wherever another
third-party sign-in is offered.

Identity is delegated to Supabase Auth — already in the stack, so no new vendor and no new
place for personal data to sit. **The subject Spling stores is the Supabase user id and
nothing else.** No email, no name, no provider token is written to a Spling table. That id
is stable, which is the whole point: the same person on a new phone gets their language,
their history and their allergens back, instead of arriving as a stranger.

Endpoints, all relative to the function URL:

| Path | What it is |
|---|---|
| `/.well-known/oauth-authorization-server` | RFC 8414 metadata |
| `/.well-known/oauth-protected-resource` | RFC 9728 metadata |
| `/register` | RFC 7591 dynamic client registration |
| `/authorize` | GET parks the request and asks who this is; POST is the answer to consent |
| `/signin` | Google, Apple, or send the email link |
| `/auth/callback` | back from the provider, then the consent screen |
| `/token` | code exchange + refresh rotation |
| `/revoke` | RFC 7009 |

An unauthenticated request answers `401` with a `WWW-Authenticate` header pointing at
discovery — that header is what lets an assistant walk someone through a login instead of
asking a human for a secret.

The flow, and why it is shaped this way:

```
assistant → /authorize        validate once, write the request down, return an
                              unguessable reference
person    → /signin           Google · Apple · email link
          → Supabase Auth     the person authenticates somewhere Spling never sees
          → /auth/callback    exchange the code, keep only the user id
          → consent screen    plain language, real form, no JavaScript
person    → /authorize POST   reference only; everything else read back from the row
assistant ← code              → /token → access + refresh
```

The request is held server-side because the person leaves mid-flow. That also closes a
hole: the consent form used to re-post the client's PKCE challenge and redirect URI as
hidden fields, so a page in the middle could swap them. Now the browser carries a
reference and nothing else.

Deliberately not implemented: implicit grant, password grant, and PKCE `plain`. OAuth 2.1
removes them and this server is new, so there is nothing to stay compatible with. Refresh
tokens rotate on use, and a replayed authorization code revokes every live token for that
person — we cannot tell which presentation was genuine, so the safe answer is all of them.

**One known sharp edge.** Supabase links identities that share a verified email, so
Google-then-Apple usually resolves to one user. Apple Private Relay hands over a
`@privaterelay.appleid.com` address, which will not match a Google one — that person
becomes two subjects with two profiles. `export_profile` is the escape hatch until
explicit account linking exists; it is on the list, not in the code.

`SPLING_BEARER` still works for local development. It resolves every caller to one
subject, which is fine alone and wrong the moment two people use it — they would share a
profile, including one person's allergens. Do not set it anywhere real people can reach.

## First run

Sign in, then talk. There is no settings screen, deliberately. When `get_profile` finds an empty profile it
returns `first_run: true` and instructions telling the assistant to set it up
conversationally — three plain questions, in whatever language the person is already
writing in, each one skippable, saved as they go so nothing is lost if they stop halfway.

© 2026 R-evolv Inc.
