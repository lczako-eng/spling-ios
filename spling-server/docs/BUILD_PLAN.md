# Spling — One-Week Build Plan

Each day ends with a verified checkpoint. If a checkpoint fails, the next day does not start.
Claude Code: work one task at a time, verify, then proceed.

## Day 1 — Foundation live
- [ ] Create Square Developer app → copy SANDBOX access token
- [ ] Create new Supabase project (NOT the Rooted project) → note project ref
- [ ] `supabase link --project-ref <ref>`
- [ ] `supabase db push` (applies 001_init.sql)
- [ ] `supabase secrets set SQUARE_ACCESS_TOKEN=<sandbox> SQUARE_ENV=sandbox SPLING_BEARER=<random-64-char>`
- [ ] `supabase functions deploy spling-mcp --no-verify-jwt`
- [ ] Seed the Square sandbox catalog: create 6–10 items with modifiers in the
      Square sandbox dashboard (e.g., a coffee with size + milk modifiers, a sandwich
      with bread + toppings). Realistic menu = realistic testing.
- ✅ CHECKPOINT: `curl -X POST <fn-url> -H "Authorization: Bearer <token>" -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'` returns 9 tools.

## Day 2 — Claude speaks to it
- [ ] Add as Claude custom connector (Settings → Connectors → Add custom connector,
      URL = function URL, bearer = SPLING_BEARER)
- [ ] Ask Claude: "What's on the menu?" → real items with real prices
- ✅ CHECKPOINT: menu renders in a Claude conversation from the live sandbox catalog.

## Day 3 — Order composition (Phase 2a)
- [ ] Implement `compose_order`: takes {location_id, items:[{name_or_id, qty, modifiers[]}]},
      fuzzy-matches against live catalog, RESOLVES to exact catalog IDs,
      REJECTS anything unmatched with a clear reason, returns priced draft + total_cents.
      Deterministic validation. Log every accept/reject to order_events.
- [ ] Persist draft to `orders` (status='composed')
- ✅ CHECKPOINT: "Order a large oat-milk latte and a turkey sandwich no onions" →
  correctly priced draft; "add a unicorn burger" → clean rejection.

## Day 4 — Order lands + payment (Phase 2b)
- [ ] Implement `place_order`: create Square Order (POST /v2/orders) →
      create Payment Link (POST /v2/online-checkout/payment-links) →
      status='payment_pending', store checkout_url, generate pickup_code "SPL-XXXX"
- [ ] Implement `get_order_status`
- [ ] Square webhook (or poll) → status='paid' → 'submitted'
- ✅ CHECKPOINT: 10 consecutive sandbox orders: composed → paid (test card 4111...) → visible
  in Square sandbox dashboard. THE THESIS IS PROVEN HERE.

## Day 5 — Language (Phase 3) — THE PRODUCT
- [ ] `get_profile` / `update_profile` (compose_language, receipt_language, dietary)
- [ ] Cross-language composition: user utterance in ANY language → compose_order
      resolves against the English catalog. The assistant does the understanding;
      Spling's validator guarantees only real items pass. Store user_utterance +
      utterance_language on the order for the user's own history.
- [ ] Dietary enforcement: 'anaphylaxis' severity blocks the item hard; 'strict' requires
      explicit override; 'preference' warns.
- ✅ CHECKPOINT: 10 consecutive orders in Hungarian/French/Spanish land as correct
  English line items. Allergen block verified.

## Day 6 — Profile depth + ledger start (Phases 4–5)
- [ ] communication_profiles CRUD via update_profile
- [ ] `get_history` ("the usual" = most frequent line_items)
- [ ] `export_profile` in PAM JSON (schema: portable-ai-memory v1.0)
- [ ] `submit_correction` + verify merchant_accuracy view populates
- ✅ CHECKPOINT: full loop — profile set → order in another language → correction filed →
  accuracy view shows it.

## Day 7 — Website + package
- [ ] spling.org update per docs/WEBSITE_BRIEF.md
- [ ] README polish, .env.example check, secrets audit (nothing in git)
- [ ] Record a 60-second demo: phone → Claude → order in another language → paid → pickup code
- ✅ CHECKPOINT: a stranger can watch the demo and understand the product in one minute.

## Explicitly OUT of this week
OAuth 2.1 + DCR (ChatGPT path) — week 2. iOS app — later. Geofencing — after iOS app.
Real merchant onboarding — after sandbox proof. NFC — indefinitely deferred.
