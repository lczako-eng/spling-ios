# Standing the connector up

The runbook for getting from an empty Supabase account to a real order placed by a real
person. Roughly an hour, most of it waiting on dashboards.

Nothing in this file can be done by Claude Code — every step needs an account, a payment
method, or a credential. What follows is written so it can be followed exactly.

---

## 0. The one irreversible decision

**Pick the region before you click Create, because it cannot be changed afterwards.**
Changing it later means creating a second project and migrating everything into it.

For R-evolv, the region should be **Canada (Central) — `ca-central-1`** — but not for the
reason people usually give.

**PIPEDA does not require data residency.** It permits transfers outside Canada provided
the organization stays accountable for the data and is transparent that transfers happen.
Anyone who tells you Canadian personal data must stay in Canada under PIPEDA is wrong. The
real arguments are these three:

1. **EU adequacy.** Canada holds an adequacy decision from the European Commission for
   commercial organizations subject to PIPEDA — the United States does not hold an
   equivalent unqualified one. For a product intended to run everywhere, a Canadian region
   is the single jurisdiction that reaches both North America and the EEA without a
   transfer mechanism bolted on. That makes this a *global* choice, not a patriotic one.
   Confirm the current state of that decision with counsel before relying on it in a
   contract; it has been reviewed more than once.
2. **Public-sector procurement.** Hospitals, government service desks and public
   institutions are on Spling's own venue list. Some Canadian public-sector privacy law —
   British Columbia and Nova Scotia most notably — has carried genuine residency
   requirements, and Quebec's Law 25 imposes assessment obligations on transfers out of
   the province. This is where residency actually bites, and it bites on exactly the
   customers this product wants.
3. **It is free to be right now and expensive to fix later.**

**Do not shard the database by geography.** One project, one region, worldwide. The
accuracy ledger and the lexicon corpus are only worth something because they aggregate;
splitting them by country to satisfy a requirement nobody has imposed yet destroys the
asset to solve a hypothetical. Add a second region when a signed contract demands it.

While you are on that screen: create the project in an **R-evolv organization**, not a
personal one, and do **not** reuse the Rooted project (`CLAUDE.md`, Environment).

Two other plan-level notes:

- Free-tier projects **pause after about a week of inactivity**. Fine for building, not
  fine for a demo with someone sitting next to you. Move to a paid plan before any session
  where a real person is testing.
- Point-in-time recovery is a paid add-on. The accuracy ledger is the asset; a nightly
  backup is not the same as being able to rewind an hour.

## 1. Create and link

```bash
supabase login
supabase link --project-ref <project-ref>     # from Project Settings → General
supabase db push                              # applies migrations 001–005
```

`db push` should report five migrations. If it reports fewer, stop — the schema is the
thing everything else assumes.

## 2. Sign-in

Dashboard → **Authentication → Providers**

- Enable **Google** (needs a Google Cloud OAuth client — client ID and secret)
- Enable **Apple** (needs an Apple Developer account, a Services ID and a key)
- Leave **Email** enabled — this is the path for people who have neither, which is a large
  share of the people this is built for

Dashboard → **Authentication → URL Configuration → Redirect URLs**

Add exactly:

```
https://<project-ref>.supabase.co/functions/v1/spling-mcp/auth/callback
```

Supabase refuses to redirect anywhere not on that list. That refusal is what stops the
sign-in flow being pointed at someone else's server, so the entry has to be exact.

**Apple caveat, worth knowing before it surprises you.** Private Relay hands over a
`@privaterelay.appleid.com` address, which will not match a Google account's email — so
one person signing in with Google and later with Apple can become two subjects with two
profiles. Until explicit account linking exists, tell testers to use the same button every
time.

## 3. Square sandbox

developer.squareup.com → new application → **Sandbox** access token.

Then the step people skip: **build a small catalogue in the sandbox dashboard.** An empty
catalogue means `get_catalog` returns nothing and there is nothing to order. Five or six
items is enough, but they must be realistic:

- at least two items with **multiple sizes** (this is where most real errors happen)
- at least one item with a **modifier list** — milk, sauce, add-ons
- prices that are not round numbers, so arithmetic bugs are visible

Note the **location ID** — Locations in the sandbox dashboard.

## 4. Secrets

```bash
supabase secrets set \
  SQUARE_ACCESS_TOKEN=<sandbox token> \
  SQUARE_ENV=sandbox \
  SUPABASE_URL=https://<project-ref>.supabase.co \
  SUPABASE_ANON_KEY=<anon key> \
  SUPABASE_SERVICE_ROLE_KEY=<service role key>
```

**Do not set `SPLING_BEARER`.** It resolves every caller to one subject, so two people
using it share one profile — including one person's allergens. It exists for local
development and nothing else.

Keys are in Project Settings → API. The service role key bypasses RLS; it belongs in
Supabase secrets and nowhere else — never in the repo, never in the iOS app, never in a
browser.

## 5. Deploy

```bash
supabase functions deploy spling-mcp --no-verify-jwt
```

`--no-verify-jwt` is deliberate: MCP handles its own auth, and Supabase's gateway would
otherwise reject the OAuth discovery requests before they reach the function.

## 6. Verify before you involve anyone

```bash
FN=https://<project-ref>.supabase.co/functions/v1/spling-mcp

# unauthenticated: must refuse, and must say where to sign in
curl -si "$FN" | grep -i www-authenticate

# discovery: must return JSON, with S256 and no 'plain'
curl -s "$FN/.well-known/oauth-authorization-server" | jq .code_challenge_methods_supported

# the consent flow renders: should return HTML, not JSON
curl -s "$FN/.well-known/oauth-protected-resource" | jq .authorization_servers
```

If the first command returns nothing, the function is not reachable and nothing else will
work.

## 7. Connect an assistant

Claude → Settings → Connectors → Add custom connector → paste the function URL.

There is no secret to paste. The assistant registers itself (RFC 7591), discovers the
authorization server, and hands the person a **Sign in** button. That is the whole point
of the OAuth work — if a tester is ever asked for a token, something is misconfigured.

First run has no settings screen: `get_profile` returns `first_run: true` and the
assistant asks three plain questions in whatever language the person is already writing
in, each one skippable.

## 8. What to watch on the first real order

- `orders` and `order_events` should both have rows — `order_events` is the audit trail
- the Square sandbox dashboard should show the same order
- the line items in Square must contain **catalog IDs only**, never human strings
- `profiles` should have exactly one row per human, not per device

If two testers end up sharing a profile, `SPLING_BEARER` is set somewhere. Unset it.

---

## Who owns what

Worth being precise about, because it is both the commercial question and the legal one,
and the answers are different for the two halves.

**The individual's data is theirs, by design and by promise.** The communication profile,
the language, the allergens, the history: it exports in PAM, the site says so out loud,
and `export_profile` exists specifically so a person can leave. That is not a concession —
it is the reason someone with allergies is willing to enter them in the first place. It is
also health-adjacent under PIPEDA, which makes any claim of ownership over it a liability
rather than an asset.

**The aggregate is R-evolv's, and it is the part that compounds.** Three things nobody
else is accumulating:

- the **accuracy ledger** — per-merchant, per-location, per-item accuracy over time
- the **lexicon corpus** in aggregate — which words collapse into which, on which
  recogniser, without reference to any individual
- the **composition corpus** — utterance in any language paired with the validated order
  it resolved to, which is a kind of labelled data that essentially does not exist publicly

None of those are any one person's data, and none of them are portable out with a profile.
That is the asset, and it grows with every order rather than with every user.

**One honest caveat on "nobody else's".** Supabase is a managed host, so Supabase the
company operates the infrastructure the data sits on, under their terms and DPA. That is
normal and is what every hosted database means. If sole custody ever becomes a
requirement — a hospital contract, a government tender — the answer is self-hosted
Postgres, which is a real operational cost and a decision to make when a contract demands
it, not before.

© 2026 R-evolv Inc.
