# spling.org — Redesign Brief

## The page's single job
Make one sentence land in five seconds:
**"Your AI assistant is your mouth. Order in your language, without speaking, anywhere."**
Everything else on the page supports that sentence or gets cut.

## Audience (in priority order)
1. People failed by the spoken channel — speech differences, deaf/HoH, AAC users, non-native speakers
2. Their caregivers and family
3. Disability organizations and settlement services (institutional buyers)
4. Merchants (a single quiet section — Square handles their side; we need one line, not a pitch)

## What changed from the old site
The old positioning (NFC tap-to-order, six-module "transaction infrastructure") is retired.
Remove all NFC/tap language, module grids, and enterprise-infrastructure copy.
Spling is now one thing: assistant-mediated ordering with a portable communication + language profile.

## Design direction

**Signature element — the conversation, played straight.**
The hero is a real chat exchange rendered large, not a screenshot:
a message in Hungarian ("Rendelnél nekem egy nagy lattét zabtejjel?") →
the assistant's reply → a clean order card in English (1× Large Latte, Oat Milk — $6.25 — SPL-4B2F).
The translation happening across two chat bubbles IS the product demo. Animate the exchange
once on load (typewriter for the incoming message, then the order card resolving), respect
prefers-reduced-motion with a static final frame.

**Type.** Display: a rounded, humanist grotesque with real warmth at heavy weights
(e.g., "Bricolage Grotesque" or "Schibsted Grotesk" — characterful, not corporate).
Body: "Atkinson Hyperlegible" — designed by the Braille Institute for low-vision readers.
Using it is not just a choice, it's an argument: the accessibility positioning is embodied
in the letterforms. Mention it in the footer ("Set in Atkinson Hyperlegible"). Utility/mono
for order cards and pickup codes: "Spline Sans Mono" (yes, the near-namesake is a bonus).

**Palette.** Ink #1D1B16 · Paper #FBF9F4 · Order-card green #1E6B4F ·
Signal amber #E8A33D (used ONCE — on the pickup code) · Bubble grey #ECE8DF.
No gradients. The order card is the only saturated object on the page; it should feel
like the receipt you actually get.

**Layout.** Single column, generous, calm. Max-width ~680px for prose. The page reads
top to bottom like the transaction it describes:
  1. Hero conversation (the signature)
  2. One paragraph: the problem (drive-thru accuracy numbers, the speaker in traffic)
  3. Three short rows, icon-free, plain-language: Your language · Your profile · Your record
     (each is two sentences, not a card grid)
  4. "Works with Claude and ChatGPT" — wordmarks, one line
  5. Caregiver staging: one warm paragraph + a small second chat exchange showing a
     staged order being finalized with one tap
  6. Quiet merchant line: "On Square? You're already compatible." + contact
  7. Footer: Atkinson credit, R-evolv Inc., contact

**Accessibility is the floor, loudly kept.** WCAG AA minimum, AAA contrast for body text.
Full keyboard navigation, visible focus rings, semantic landmarks, alt text on the chat
exchange that narrates the transaction. The accessibility statement is a real page, not a link
to nowhere. This site will be read by screen readers as a matter of course — build for that first.

**Copy register.** Plain, warm, zero jargon. Never "empower," never "seamless," never
"revolutionize." Say what happens: "You order. They understand. Every time."

## Out of scope for this week
Merchant portal, blog, pricing page (no pricing exists yet), account system.
One page done beautifully beats five done adequately.
