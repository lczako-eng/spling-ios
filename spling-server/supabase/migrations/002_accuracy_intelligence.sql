-- ============================================================================
-- 002 — Accuracy intelligence
--
-- docs/STRATEGY.md names this the compounding moat, and commits the product to
-- answering five specific questions. 001 could not answer four of them: a
-- correction recorded a kind and a free-text item name, with no link to the
-- modifier that failed and no way to bucket by time or language.
--
-- This migration makes the ledger answerable:
--   1. Which locations are consistently accurate?      -> location_accuracy
--   2. Which modifiers fail most often?                -> modifier_failures
--   3. Which translations create confusion?            -> language_accuracy
--   4. Which merchants improve over time?              -> merchant_accuracy_monthly
--   5. Does Spling objectively reduce ordering errors? -> system_accuracy
--
-- It also fixes two defects in 001's merchant_accuracy view. See below.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Pin a correction to the thing that actually failed.
-- 'wrong_modifier' was unanswerable without this: you knew an order was wrong,
-- not that "Oat Milk" is the modifier this location drops twice a week.
-- ----------------------------------------------------------------------------
alter table public.corrections
  add column if not exists line_item_index integer,
  add column if not exists catalog_object_id text,
  add column if not exists modifier_name text,
  add column if not exists modifier_object_id text;

comment on column public.corrections.catalog_object_id is
  'Square variation id of the item that failed, when known. Lets failures be counted per catalogue entry rather than per free-text name.';
comment on column public.corrections.modifier_name is
  'The specific modifier that failed, e.g. "Oat Milk". Populated for wrong_modifier and missing_item where a modifier was involved.';

create index if not exists corrections_merchant_created_idx on public.corrections (merchant_id, created_at desc);
create index if not exists corrections_modifier_idx on public.corrections (modifier_object_id) where modifier_object_id is not null;
create index if not exists orders_merchant_status_idx on public.orders (merchant_id, status);
create index if not exists orders_utterance_language_idx on public.orders (utterance_language) where utterance_language is not null;

-- ----------------------------------------------------------------------------
-- A single definition of "an order that actually completed", so every view
-- below counts the same denominator. Accuracy figures that use different
-- denominators are worse than no figures at all.
-- ----------------------------------------------------------------------------
create or replace view public.completed_orders as
select o.*
from public.orders o
where o.status in ('submitted', 'ready', 'picked_up');

comment on view public.completed_orders is
  'The shared denominator for all accuracy views: orders that reached the merchant. Composed and failed orders never count against a merchant.';

-- ----------------------------------------------------------------------------
-- Fix for 001's merchant_accuracy.
--
-- Defect 1 (correctness): corrections were joined to merchants independently of
-- orders, so orders_with_corrections counted every correction for the merchant
-- including ones against orders that never completed. That can exceed the
-- completed-order count and drive accuracy_pct negative.
--
-- Defect 2 (exposure): a Postgres view runs as its owner, so it does NOT
-- enforce the RLS on its base tables. Exposed through PostgREST it would let
-- any caller read aggregates over other people's corrections. These views are
-- deliberately cross-user — that is the whole point of a cross-merchant
-- dataset — so the correct fix is not security_invoker, which would break the
-- aggregate. They are service-role only, and the grants at the bottom enforce
-- that explicitly rather than by assumption.
-- ----------------------------------------------------------------------------
create or replace view public.merchant_accuracy as
with completed as (
  select merchant_id, count(*)::bigint as completed_orders
  from public.completed_orders
  group by merchant_id
),
corrected as (
  select c.merchant_id, count(distinct c.order_id)::bigint as orders_with_corrections
  from public.corrections c
  join public.completed_orders o on o.id = c.order_id   -- only completed orders count
  group by c.merchant_id
)
select
  m.id as merchant_id,
  m.display_name,
  m.square_location_id,
  coalesce(cm.completed_orders, 0) as completed_orders,
  coalesce(cr.orders_with_corrections, 0) as orders_with_corrections,
  case when coalesce(cm.completed_orders, 0) > 0
    then round(100.0 * (1 - coalesce(cr.orders_with_corrections, 0)::numeric / cm.completed_orders), 1)
    else null end as accuracy_pct
from public.merchants m
left join completed cm on cm.merchant_id = m.id
left join corrected cr on cr.merchant_id = m.id;

-- ----------------------------------------------------------------------------
-- 1. Which locations are consistently accurate?
-- Consistency needs a sample size, so it is reported rather than hidden — a
-- 100% accuracy score over three orders is noise, and labelling it as such is
-- the difference between intelligence and a rating.
-- ----------------------------------------------------------------------------
create or replace view public.location_accuracy as
select
  ma.merchant_id,
  ma.square_location_id,
  ma.display_name,
  ma.completed_orders,
  ma.orders_with_corrections,
  ma.accuracy_pct,
  case
    when ma.completed_orders >= 100 then 'high'
    when ma.completed_orders >= 30  then 'moderate'
    when ma.completed_orders >= 10  then 'low'
    else 'insufficient'
  end as confidence
from public.merchant_accuracy ma;

comment on view public.location_accuracy is
  'Question 1. accuracy_pct must never be quoted without confidence — below 10 completed orders it is not a measurement.';

-- ----------------------------------------------------------------------------
-- 2. Which modifiers fail most often?
-- The interesting output is not "this merchant is bad" but "this modifier is
-- structurally fragile", which is actionable for the merchant and for us.
-- ----------------------------------------------------------------------------
create or replace view public.modifier_failures as
select
  c.merchant_id,
  m.display_name,
  coalesce(c.modifier_name, '(unspecified)') as modifier_name,
  c.modifier_object_id,
  count(*)::bigint as failures,
  count(*) filter (where c.kind = 'wrong_modifier')::bigint as wrong_modifier,
  count(*) filter (where c.kind = 'missing_item')::bigint as missing,
  min(c.created_at) as first_seen,
  max(c.created_at) as last_seen
from public.corrections c
join public.merchants m on m.id = c.merchant_id
where c.kind in ('wrong_modifier', 'missing_item', 'wrong_item')
group by c.merchant_id, m.display_name, c.modifier_name, c.modifier_object_id
order by failures desc;

comment on view public.modifier_failures is
  'Question 2. A modifier failing across many merchants is a product problem; failing at one is an operations problem.';

-- ----------------------------------------------------------------------------
-- 3. Which translations create confusion?
-- The honest framing: this measures the error rate of orders composed in a
-- given language. A high rate is a signal to inspect that language's
-- composition path — it is not proof the language caused the error.
-- ----------------------------------------------------------------------------
create or replace view public.language_accuracy as
with completed as (
  select coalesce(utterance_language, 'unspecified') as lang, count(*)::bigint as completed_orders
  from public.completed_orders
  group by 1
),
corrected as (
  select coalesce(o.utterance_language, 'unspecified') as lang,
         count(distinct c.order_id)::bigint as orders_with_corrections
  from public.corrections c
  join public.completed_orders o on o.id = c.order_id
  group by 1
)
select
  cm.lang as utterance_language,
  cm.completed_orders,
  coalesce(cr.orders_with_corrections, 0) as orders_with_corrections,
  case when cm.completed_orders > 0
    then round(100.0 * (1 - coalesce(cr.orders_with_corrections, 0)::numeric / cm.completed_orders), 1)
    else null end as accuracy_pct,
  cm.completed_orders >= 30 as sample_is_meaningful
from completed cm
left join corrected cr on cr.lang = cm.lang
order by cm.completed_orders desc;

comment on view public.language_accuracy is
  'Question 3. Compare a language against the system baseline, never against a raw threshold.';

-- ----------------------------------------------------------------------------
-- 4. Which merchants improve over time?
-- Monthly buckets, so a trend is visible rather than a single lifetime number
-- that a merchant can never move.
-- ----------------------------------------------------------------------------
create or replace view public.merchant_accuracy_monthly as
with completed as (
  select merchant_id, date_trunc('month', created_at) as month, count(*)::bigint as completed_orders
  from public.completed_orders
  group by 1, 2
),
corrected as (
  select o.merchant_id, date_trunc('month', o.created_at) as month,
         count(distinct c.order_id)::bigint as orders_with_corrections
  from public.corrections c
  join public.completed_orders o on o.id = c.order_id
  group by 1, 2
)
select
  cm.merchant_id,
  m.display_name,
  cm.month,
  cm.completed_orders,
  coalesce(cr.orders_with_corrections, 0) as orders_with_corrections,
  case when cm.completed_orders > 0
    then round(100.0 * (1 - coalesce(cr.orders_with_corrections, 0)::numeric / cm.completed_orders), 1)
    else null end as accuracy_pct
from completed cm
join public.merchants m on m.id = cm.merchant_id
left join corrected cr on cr.merchant_id = cm.merchant_id and cr.month = cm.month
order by cm.merchant_id, cm.month;

comment on view public.merchant_accuracy_monthly is
  'Question 4. Direction of travel matters more than absolute position — a merchant improving from 82 to 91 is the story.';

-- ----------------------------------------------------------------------------
-- 5. Does Spling objectively reduce ordering errors?
--
-- This view reports OUR measured rate and nothing else. It deliberately does
-- not embed a published drive-through baseline: the comparison is only honest
-- against a matched population, and hard-coding someone else's number into a
-- view is how a marketing claim gets born inside a database. Compare
-- deliberately, in the open, with the sample size attached.
-- ----------------------------------------------------------------------------
create or replace view public.system_accuracy as
with completed as (select count(*)::bigint as completed_orders from public.completed_orders),
corrected as (
  select count(distinct c.order_id)::bigint as orders_with_corrections
  from public.corrections c
  join public.completed_orders o on o.id = c.order_id
)
select
  c.completed_orders,
  r.orders_with_corrections,
  case when c.completed_orders > 0
    then round(100.0 * (1 - r.orders_with_corrections::numeric / c.completed_orders), 2)
    else null end as accuracy_pct,
  c.completed_orders >= 384 as sample_supports_a_public_claim
from completed c, corrected r;

comment on view public.system_accuracy is
  'Question 5. sample_supports_a_public_claim is 384 — the n for +/-5% at 95% confidence. Below it, we have a number, not evidence.';

-- ----------------------------------------------------------------------------
-- Exposure. These views aggregate across every user by design, so they must
-- never be reachable with an anon or end-user key. Service role only, stated
-- explicitly rather than relied on by default.
-- ----------------------------------------------------------------------------
do $$
declare v text;
begin
  foreach v in array array[
    'completed_orders', 'merchant_accuracy', 'location_accuracy', 'modifier_failures',
    'language_accuracy', 'merchant_accuracy_monthly', 'system_accuracy'
  ] loop
    execute format('revoke all on public.%I from anon, authenticated', v);
  end loop;
end $$;
