-- ============================================================================
-- 006 — the personal lexicon
--
-- Spling never hears anyone. Recognition happens inside the assistant and MCP
-- carries text, so there is no audio here and there should not be: the moment
-- this system handles voice recordings it inherits a category of exposure it
-- currently does not have.
--
-- What this stores is a table of (heard → meant) pairs belonging to one person:
-- how their assistant mishears them, learned from their own corrections and a
-- short calibration. It is the same machinery as cross-language matching —
-- compose.ts already folds "lattét" onto "Latte"; this is that normalisation
-- keyed to a person instead of to a script.
--
-- Speech patterns are health-adjacent under PIPEDA. Same rules as
-- communication_profiles: never logged, never in an error message, never sent
-- to a merchant, and never pooled across people.
--
-- Design and interaction rules: docs/LEXICON.md.
-- ============================================================================

create table if not exists public.lexicon_entries (
  id uuid primary key default uuid_generate_v4(),
  profile_id uuid not null references public.profiles(id) on delete cascade,

  /* Both sides stored normalised — lowercased, diacritics folded, punctuation
     collapsed — by the same function compose.ts uses, so a lookup here and a
     match there cannot disagree. */
  heard text not null,
  meant text not null,

  source text not null default 'correction'
    check (source in ('calibration','correction')),

  /* Which recogniser produced this. Claude's and ChatGPT's fail differently, so
     a pair learned from one is not necessarily true of the other. Null means
     unknown, which is treated as applying everywhere. */
  client_id text,

  /* Ordering only. Never a confidence score, and never a licence to guess: an
     entry with a thousand hits still cannot resolve an ambiguity. */
  hits integer not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  /* One meaning per heard form per person. A second one would be an ambiguity
     the lexicon is not allowed to resolve. */
  constraint lexicon_entries_unique_heard unique (profile_id, heard),

  /* Nothing may be learned that teaches nothing, at the storage layer as well
     as in code — a bug in the application must not be able to write a pair that
     fires on everything. */
  constraint lexicon_entries_distinct check (heard <> meant),
  constraint lexicon_entries_bounds check (
    char_length(heard) between 2 and 60 and char_length(meant) between 2 and 60
  )
);

create index if not exists lexicon_entries_profile_idx on public.lexicon_entries (profile_id);

comment on table public.lexicon_entries is
  'How one person''s assistant mishears them. Health-adjacent: never logged, never sent to a merchant, never pooled.';

-- ----------------------------------------------------------------------------
-- Calibration progress. Kept separate from the pairs because it is a record of
-- what was asked, not of what was learned — and because the most important
-- thing it holds is not a pair at all.
-- ----------------------------------------------------------------------------
create table if not exists public.lexicon_calibration (
  profile_id uuid primary key references public.profiles(id) on delete cascade,

  /* Sets completed, by key. Partial is normal and expected: the calibration is
     skippable at every word and resumable later, so most people will be here
     with some of it done and no reason ever asked for. */
  sets_done text[] not null default '{}',

  /* Negation words that did not survive transcription for this person. This
     never becomes a substitution — a dropped "no" does not produce a wrong
     order, it produces the thing they cannot eat, so a probabilistic fix is
     exactly wrong. It raises the bar instead: dietary constraints get confirmed
     out loud for this person, permanently. */
  negation_unreliable text[] not null default '{}',

  updated_at timestamptz not null default now()
);

comment on column public.lexicon_calibration.negation_unreliable is
  'Negation words this person''s assistant loses. Never substituted; triggers explicit dietary confirmation instead.';

-- ----------------------------------------------------------------------------
-- Exposure. Same posture as every other table holding health-adjacent data:
-- the owner reaches their own row and nothing else, and the service role does
-- the work.
-- ----------------------------------------------------------------------------
alter table public.lexicon_entries      enable row level security;
alter table public.lexicon_calibration  enable row level security;

create policy "own lexicon" on public.lexicon_entries
  for all using (profile_id in (select id from public.profiles where auth_user_id = auth.uid()))
  with check (profile_id in (select id from public.profiles where auth_user_id = auth.uid()));

create policy "own calibration" on public.lexicon_calibration
  for all using (profile_id in (select id from public.profiles where auth_user_id = auth.uid()))
  with check (profile_id in (select id from public.profiles where auth_user_id = auth.uid()));

revoke all on public.lexicon_entries     from anon;
revoke all on public.lexicon_calibration from anon;
