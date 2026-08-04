# Spling — Strategic Direction

**Read before making any changes.** This document outranks feature requests. If a proposed
change does not reinforce one of the three moats, the correct answer is usually no.

---

## What this is not

This is not another AI ordering application.

Ordering, reservations, payments and merchant integrations are becoming commodity
infrastructure. We inherit those capabilities wherever they exist. They are not our
competitive advantage, and building them is not progress.

## What this is

> **Spling removes the communication barrier between a person and a merchant, anywhere
> that communication is required.**

The drive-through speaker was the original inspiration. It is the clearest demonstration
of the problem — **it is not the market.**

Spling should work at drive-throughs, restaurant counters, cafés, hotels, airports,
retail, hospitals, stadiums, government service counters, and anywhere else a person must
communicate with a business.

**The communication layer is the product. Ordering is simply its first application.**

---

## Geofencing is context, not innovation

Location is a trigger. It is not a feature to be proud of.

When a user arrives somewhere known, Spling should already have loaded:

- where they are
- which merchant they are visiting
- what menu or services are available
- their language
- their communication profile
- their dietary and accessibility requirements
- their preferences

The value is that **nothing has to be re-established.** The location merely says *when* to
load the context. Anyone can draw a circle on a map; the context is the point.

---

## The three moats

Everything built should reinforce one of these. Nothing else is defensible.

### 1. Language composition

A user communicates in whatever language they naturally use.

Spling does **not** merely translate text. It composes a **validated structured
transaction** that matches the merchant's live system. The merchant receives exactly what
their POS understands — item IDs, modifier IDs, quantities — never a translated sentence
somebody still has to interpret.

Translation is another lossy hop. Composition is not.

### 2. Communication profile

**Speech is optional.**

Whether someone has a speech difference, deafness, aphasia, autism, anxiety, a temporary
injury, or simply cannot be understood through poor audio — Spling carries that profile
everywhere.

**The user never has to explain themselves again.** That sentence is the product promise;
protect it.

### 3. Accuracy intelligence

The most valuable long-term asset is not ordering. It is owning the full chain:

```
Intent → Structured Order → Merchant Output → Actual Result → Correction
```

Every completed interaction improves the system. Nobody currently owns this cross-merchant
accuracy dataset.

This is **operational intelligence, not reviews.** It answers questions no one else can:

- Which locations are consistently accurate?
- Which modifiers fail most often?
- Which translations create confusion?
- Which merchants improve over time?
- Does Spling objectively reduce ordering errors?

This dataset compounds forever, and it cannot be back-dated by anyone starting later.

---

## Website goal

A visitor must never leave thinking *"this is another AI ordering app."*

They should immediately understand:

> **Spling removes communication barriers everywhere commerce happens.**
> Ordering is the first application. The communication layer is the product.
> The accuracy intelligence is the moat.

Every design decision, animation, interaction and line of copy is measured against that.

---

## Applying this

When evaluating any proposed change, in order:

1. Does it reinforce language composition, the communication profile, or accuracy
   intelligence? If not, it is probably scope drift.
2. Does it make the product read as ordering-specific when it is not? Broaden it.
3. Does it require the user to explain themselves again? Then it is a bug, whatever the
   ticket says.
4. Is it commodity infrastructure someone else already operates? Inherit it.

© 2026 R-evolv Inc.
