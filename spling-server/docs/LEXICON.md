# The personal lexicon

**Status: built.** `lexicon.ts` (pure, 18 tests), migration 006, and wired into
`compose_order` and the profile tools. Unproven against a real recogniser — no one has
been misheard by it yet.

---

## The thing to be clear about first

**Spling never hears anyone.** Speech recognition happens inside Claude or ChatGPT,
before a single byte reaches this connector. MCP carries text. There is no audio channel,
and there should not be one — the moment Spling handles voice recordings it inherits a
category of privacy exposure it currently does not have.

So the lexicon does not learn how a person speaks. It learns **how their assistant
mishears them**, which is a different and better thing to model:

- it is per-assistant, because Claude's recogniser and ChatGPT's fail differently
- it needs no audio, no model training, and no new vendor
- it is a small table of text pairs, which means it is portable, inspectable, and
  deletable by the person it describes

The person says "large thauthage". The assistant transcribes "large thauthage". Spling
stores `thauthage → sausage` **for that person**. Next time, the token resolves before the
catalogue matcher ever sees it.

## Why this is the same machinery as language, not a second feature

`compose.ts` already strips diacritics so `lattét` resolves to `Latte`. That is a
normalisation pass in front of the matcher, keyed to a script.

A personal lexicon is the identical pass, keyed to a person instead of a script.

That matters for positioning as much as for code: a lisp and a second language are not
two problems Spling happens to solve. They are one problem — language left a person and
did not arrive — and this is one mechanism.

## Where entries come from

**1. Continuous, from real use.** Every time a composition is rejected and the person
restates it, that is a labelled pair: what the assistant heard, and what they meant. This
is free, it is the highest-quality signal available, and it needs no ceremony. It should
be the primary source.

**2. Cold start, from a short calibration.** The problem with (1) alone is that the first
few orders are the worst ones, and first impressions are what decide whether someone comes
back. A twenty-word calibration buys a working lexicon before the first real order.

The calibration runs entirely through the assistant: the connector returns a list of
words, the assistant asks the person to say them, the assistant reports what it
transcribed, and the connector stores the pairs where target and transcript disagree.
Spling supplies the script and keeps the result. It never touches the microphone.

## The word list

The instinct is to reach for a phonetics-lab passage — the Rainbow Passage, the Harvard
sentences. That is the wrong tool. Those exist to characterise a speaker's phonology in
general. We do not need a phonological model. We need to resolve **menu items**, and
nothing else.

So every calibration word is a word someone actually orders with. Four sets of five,
ordered by what a mistake costs.

### Set 1 — negation (5 words)
The highest-stakes set, and the one nobody thinks to test. A dropped "no" does not
produce a wrong order. It produces the thing the person cannot eat.

`no` · `without` · `hold the` · `none` · `allergic`

If any of these are unreliable for a given person, that fact should raise the bar on
dietary confirmation for them permanently — see *Safety* below.

### Set 2 — sizes (5)
The most frequent error in fast food, and the one both parties argue about at the window.

`small` · `medium` · `large` · `extra large` · `double-double`

`small` and `tall` are the classic collision; `double-double` is worth its place both as
a plosive cluster and because it is the single most-ordered phrase in the country this is
being built in.

### Set 3 — quantity (5)
A wrong number is a wrong order, and numbers are short, unstressed and easy to lose.

`one` · `two` · `three` · `ten` · `fifteen`

`two` and `to` and `too` are homophones the recogniser cannot separate on sound alone;
what we are testing is whether the *number* survives at all.

### Set 4 — sibilants and clusters (5)
Where a lisp, dysarthria, and high-frequency hearing loss all leave marks — chosen so
every word is also orderable.

`sausage` · `cheese` · `iced` · `espresso` · `croissant`

`sausage` carries two sibilants and an affricate in three syllables; `iced` is a
consonant cluster that routinely disappears, turning an iced coffee into a hot one.

### After the first orders, personalise it
Once someone has history, the best calibration set is not this one — it is **the twenty
words they personally order most**. Mine the history, calibrate on that. That is the
version that compounds, and the version a competitor cannot copy without the person.

## The psychology, which is most of the work

Everything below is a design rule, not a suggestion. Get these wrong and the feature is
worse than not shipping it, because the people it is for have spent their lives being
assessed on exactly this.

**Never call it a test.** It is not a test. Nobody is being measured. The system is being
calibrated, and the words are for its benefit, not theirs. Say "let's teach it your
voice," never "let's see how you say these."

**Never show them what it misheard.** This is the most important rule on the page. Storing
`thauthage` is necessary. Displaying `thauthage` back to a person is holding up a mirror
they did not ask for, in a product that exists so they never have to look in it. The
transcript is internal, permanently.

**No score. No percentage. No accuracy bar.** There is no number that helps here and
several that wound.

**Skippable at every single word, resumable at any point.** Speech degrades with effort —
sharply, for dysarthria and for fatigue-linked conditions. Twenty words in one sitting can
be too many, and the person should never have to explain why they stopped.

**Never ask for a third attempt.** If a word does not resolve twice, move on and learn it
from real use instead. Asking someone to repeat themselves a third time is precisely the
drive-through experience this product exists to abolish. Do not rebuild it in the
onboarding.

**Show a win at five words, not at twenty.** Demonstrate something it now gets right
before asking for the rest. Motivation has to arrive before completion, or completion
does not.

**Let them swap a word out without giving a reason.** Some people avoid particular words,
and the reason is theirs.

**Private by construction.** This is done at home, alone, on their own time. Never at a
counter, never with a queue, never with a caregiver reading over their shoulder unless
they asked for that.

**Theirs to delete and theirs to take.** The lexicon is a model of a person's voice. It
exports in PAM alongside everything else, and deleting it removes it, not hides it.

## Safety: the lexicon proposes, the validator still disposes

The whole value of `compose.ts` is that it does not guess. A lexicon is a guessing engine
bolted to the front of it, and if that is done carelessly it destroys the property the
product is built on.

Non-negotiable rules:

1. A lexicon entry resolves a **token**, then the catalogue matcher runs exactly as it
   does today. Resolution is not a bypass.
2. If a lexicon-resolved token produces ambiguity, that is still a question, never a
   guess. The existing refusal path applies unchanged.
3. A lexicon entry may **never** cross a dietary constraint silently. If a resolved token
   touches an anaphylaxis-severity item, it requires explicit confirmation — a hard block
   stays a hard block, and a probabilistic substitution is not evidence.
4. Entries are per-person and per-assistant. They are never pooled, never used to seed
   another user's lexicon, and never sent to a merchant.
5. Speech-pattern data is health-adjacent under PIPEDA. Same rules as
   `communication_profile`: never logged, never in an error message, never transmitted.

## Honest limits

- A lexicon fixes **consistent** mishearing. That is the common case for a lisp — the
  substitution is systematic, which is exactly why this works — but if a recogniser
  produces different garbage every time, there is nothing to learn.
- It cannot help when the assistant produces nothing at all.
- It does not improve the recogniser. It compensates for it, downstream.
- Twenty words is a starting lexicon, not a finished one. The real one accumulates.

## What was built

- `006_lexicon.sql` — `lexicon_entries` and `lexicon_calibration`, RLS as everywhere else,
  with the "teaches nothing" rules enforced as table constraints so an application bug
  cannot write a pair that fires on everything
- `lexicon.ts` — pure, no I/O. `composeWithLexicon` composes the request as it arrived,
  rewrites **only** the lines that failed, and keeps the second result **only if it is
  strictly better**. That is what stops it becoming a bypass.
- wired into `compose_order`; the calibration rides on `get_profile` and `update_profile`
  rather than adding tools, so the surface stays at nine
- `lexicon_test.ts` — 18 tests, including that negation is unlearnable in either
  direction, that ambiguity is still a question, that a working order is never rewritten,
  and that an anaphylaxis block stands regardless

Still open: nothing decays. An entry learned once is kept forever, and a recogniser that
improves will leave stale pairs behind. Hits are recorded but not yet used to retire
anything.

© 2026 R-evolv Inc.
