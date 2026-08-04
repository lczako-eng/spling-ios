-- Spling schema v1 — all phases. Apply once. RLS on everything.

create extension if not exists "uuid-ossp";

-- ============================================================
-- USERS & PROFILES
-- ============================================================
create table public.profiles (
  id uuid primary key default uuid_generate_v4(),
  auth_user_id uuid references auth.users(id) on delete cascade,
  display_name text,
  -- Language: BCP 47 tags. compose language = what the user speaks to their assistant.
  compose_language text not null default 'en',
  receipt_language text not null default 'en',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Health-adjacent data isolated in its own table so it can carry stricter policy,
-- separate retention, and is NEVER joined into order payloads sent to merchants.
create table public.communication_profiles (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  -- e.g. 'nonverbal', 'speech_difference', 'deaf', 'hoh', 'aac_user', 'none'
  communication_mode text not null default 'none',
  notes_private text,                          -- user's own words; never transmitted
  caretaker_staging_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

create table public.dietary_constraints (
  id uuid primary key default uuid_generate_v4(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('allergen','diet','dislike')),
  value text not null,                         -- e.g. 'peanut', 'halal', 'no_onion'
  severity text not null default 'preference' check (severity in ('preference','strict','anaphylaxis')),
  created_at timestamptz not null default now()
);

-- ============================================================
-- MERCHANTS (thin — Square is the source of truth)
-- ============================================================
create table public.merchants (
  id uuid primary key default uuid_generate_v4(),
  square_location_id text unique not null,
  display_name text not null,
  merchant_language text not null default 'en',
  timezone text not null default 'America/Toronto',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ============================================================
-- ORDERS
-- ============================================================
create table public.orders (
  id uuid primary key default uuid_generate_v4(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  merchant_id uuid not null references public.merchants(id),
  square_order_id text,
  status text not null default 'draft'
    check (status in ('draft','composed','payment_pending','paid','submitted','ready','picked_up','cancelled','failed')),
  -- What the user said, in their language (for their own history — not sent to merchant)
  user_utterance text,
  utterance_language text,
  -- The validated structured order — the ONLY thing that reaches the merchant
  line_items jsonb not null default '[]',       -- [{catalog_object_id, name, qty, modifiers:[], base_cents}]
  total_cents integer not null default 0,
  currency text not null default 'CAD',
  checkout_url text,
  pickup_code text,
  staged_by uuid references public.profiles(id), -- caretaker staging (Phase 4+)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Full audit trail — the Pulse Engine conscience for orders.
create table public.order_events (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  event text not null,          -- 'composed','item_rejected','validated','payment_link_created',...
  detail jsonb not null default '{}',
  created_at timestamptz not null default now()
);

-- ============================================================
-- ACCURACY LEDGER (Phase 5) — the compounding asset
-- ============================================================
create table public.corrections (
  id uuid primary key default uuid_generate_v4(),
  order_id uuid not null references public.orders(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  merchant_id uuid not null references public.merchants(id),
  item_name text,
  kind text not null check (kind in ('missing_item','wrong_item','wrong_modifier','wrong_quantity','quality','other')),
  ordered jsonb,
  received jsonb,
  note text,
  created_at timestamptz not null default now()
);

create view public.merchant_accuracy as
select
  m.id as merchant_id,
  m.display_name,
  count(distinct o.id) filter (where o.status in ('picked_up','ready','submitted')) as completed_orders,
  count(distinct c.order_id) as orders_with_corrections,
  case when count(distinct o.id) filter (where o.status in ('picked_up','ready','submitted')) > 0
    then round(100.0 * (1 - count(distinct c.order_id)::numeric /
         count(distinct o.id) filter (where o.status in ('picked_up','ready','submitted'))), 1)
    else null end as accuracy_pct
from public.merchants m
left join public.orders o on o.merchant_id = m.id
left join public.corrections c on c.merchant_id = m.id
group by m.id, m.display_name;

-- ============================================================
-- RLS — every table, no exceptions
-- ============================================================
alter table public.profiles enable row level security;
alter table public.communication_profiles enable row level security;
alter table public.dietary_constraints enable row level security;
alter table public.merchants enable row level security;
alter table public.orders enable row level security;
alter table public.order_events enable row level security;
alter table public.corrections enable row level security;

create policy "own profile" on public.profiles
  for all using (auth.uid() = auth_user_id) with check (auth.uid() = auth_user_id);

create policy "own comm profile" on public.communication_profiles
  for all using (profile_id in (select id from public.profiles where auth_user_id = auth.uid()))
  with check (profile_id in (select id from public.profiles where auth_user_id = auth.uid()));

create policy "own dietary" on public.dietary_constraints
  for all using (profile_id in (select id from public.profiles where auth_user_id = auth.uid()))
  with check (profile_id in (select id from public.profiles where auth_user_id = auth.uid()));

create policy "merchants readable" on public.merchants for select using (true);

create policy "own orders" on public.orders
  for all using (profile_id in (select id from public.profiles where auth_user_id = auth.uid())
                 or staged_by in (select id from public.profiles where auth_user_id = auth.uid()))
  with check (profile_id in (select id from public.profiles where auth_user_id = auth.uid())
              or staged_by in (select id from public.profiles where auth_user_id = auth.uid()));

create policy "own order events" on public.order_events
  for select using (order_id in (select id from public.orders where profile_id in
    (select id from public.profiles where auth_user_id = auth.uid())));

create policy "own corrections" on public.corrections
  for all using (profile_id in (select id from public.profiles where auth_user_id = auth.uid()))
  with check (profile_id in (select id from public.profiles where auth_user_id = auth.uid()));

-- updated_at maintenance
create or replace function public.touch_updated_at() returns trigger as $$
begin new.updated_at = now(); return new; end $$ language plpgsql;

create trigger t_profiles before update on public.profiles
  for each row execute function public.touch_updated_at();
create trigger t_orders before update on public.orders
  for each row execute function public.touch_updated_at();
