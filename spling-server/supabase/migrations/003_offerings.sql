-- ============================================================================
-- 003 — Offerings: what a business publishes, when it has no point of sale.
--
-- STRATEGY.md: the layer must work at pharmacies, hotels, airports, hospitals,
-- stadiums and government service desks. Almost none of those have a Square
-- catalog, and most will never expose an API. What they do have is a list of
-- things they offer.
--
-- So a business can publish that list into Spling directly, and the composition
-- engine validates against it exactly as it validates against a live menu. The
-- catalogue is the interface; the rail behind it is an implementation detail.
-- ============================================================================

-- Which rail a merchant is on, and what its catalogue is called.
alter table public.merchants
  add column if not exists provider text not null default 'square'
    check (provider in ('square', 'directory')),
  add column if not exists catalogue_kind text not null default 'menu'
    check (catalogue_kind in ('menu','services','rooms','seating','appointments','goods')),
  add column if not exists currency text not null default 'CAD';

comment on column public.merchants.provider is
  'square = live POS catalog. directory = the business publishes its offerings here (003).';
comment on column public.merchants.catalogue_kind is
  'Drives the noun the assistant uses: a pharmacy takes a request, a hotel takes a booking, nobody orders a room.';

-- ----------------------------------------------------------------------------
-- An offering is anything a business does that someone might need to ask for:
-- a dish, a room type, a prescription pickup, an appointment, an accessible
-- seat. Variants are its priced forms; option groups are its modifiers.
--
-- Structure mirrors catalogue.ts exactly, because the composer is the consumer
-- and a shape mismatch between schema and validator is how wrong things reach
-- a counter.
-- ----------------------------------------------------------------------------
create table if not exists public.offerings (
  id uuid primary key default uuid_generate_v4(),
  merchant_id uuid not null references public.merchants(id) on delete cascade,
  /** Stable id the business uses for this thing, if it has one. */
  external_id text,
  name text not null,
  description text,
  category text,
  /* Published facts: allergens on a dish, 'wheelchair accessible' on a room,
     'photo id required' on an appointment. Constraint matching reads these.
     Absence is never treated as safety. */
  tags text[] not null default '{}',
  /* [{ id, name, price_cents, currency }] — a free service carries a
     zero-cost variant rather than none, so it is still requestable. */
  variants jsonb not null default '[]',
  /* [{ id, name, options: [{ id, name, price_cents }] }] */
  option_groups jsonb not null default '[]',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint offerings_variants_is_array check (jsonb_typeof(variants) = 'array'),
  constraint offerings_option_groups_is_array check (jsonb_typeof(option_groups) = 'array'),
  -- Nothing publishable without a requestable form. Mirrors the composer's
  -- rule that an item with no variant cannot be asked for.
  constraint offerings_has_a_variant check (jsonb_array_length(variants) > 0)
);

create unique index if not exists offerings_merchant_external_idx
  on public.offerings (merchant_id, external_id) where external_id is not null;
create index if not exists offerings_merchant_active_idx
  on public.offerings (merchant_id) where active;

create trigger t_offerings before update on public.offerings
  for each row execute function public.touch_updated_at();

-- ----------------------------------------------------------------------------
-- RLS. A catalogue is public information — that is the point of publishing it —
-- so it is readable. Writes are service-role only: a business publishes through
-- an onboarding path we control, never by an end user posting rows.
-- ----------------------------------------------------------------------------
alter table public.offerings enable row level security;

create policy "offerings readable" on public.offerings
  for select using (active);

revoke insert, update, delete on public.offerings from anon, authenticated;

comment on table public.offerings is
  'Catalogues for businesses without a POS rail. Read by the directory provider; validated against by compose.ts exactly as a Square menu is.';
