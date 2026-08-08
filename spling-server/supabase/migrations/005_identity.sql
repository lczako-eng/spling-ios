-- ============================================================================
-- 005 — identity: sign in with Google, Apple, or an email link
--
-- 004 answered "may this assistant act for someone". It could not answer "who":
-- /authorize minted a fresh random subject per grant, so the same person
-- re-connecting on a new phone arrived as a stranger — no language, no history,
-- no allergens. For a product whose promise is that you never explain yourself
-- twice, that was the promise failing.
--
-- Identity is delegated to Supabase Auth, and the subject is the Supabase user
-- id. Nothing in this migration stores an email address, a name, or a provider
-- token. Spling learns that a person exists and nothing about who they are.
--
-- The one table here holds an authorization request while its owner is away at
-- Google or Apple. It also closes a hole in 004's consent screen: the client's
-- PKCE challenge and redirect URI used to be re-posted as hidden form fields,
-- so a page in the middle could swap them. Now they are read back from the row
-- the first request created, and the browser carries only a reference.
-- ============================================================================

create table if not exists public.oauth_pending (
  /* Hashed for the same reason tokens are: the raw reference travels in a URL,
     and a leaked table must not be a set of hijackable sign-ins. */
  rid_hash text primary key,

  client_id text not null references public.oauth_clients(client_id) on delete cascade,
  /* Snapshotted so the consent screen names the same assistant the person
     started with, even if the client row is edited mid-flow. */
  client_name text not null default 'Unnamed client',
  redirect_uri text not null,
  state text not null default '',
  scopes text[] not null,

  /* The client's PKCE challenge — the assistant's, not ours. */
  code_challenge text not null,
  /* Ours, held on the person's behalf while they are at the identity provider,
     and exchanged for their user id when they come back. */
  provider_verifier text not null,

  /* Null until sign-in completes. A consent POST with this still null is a
     forged consent, and is refused. */
  subject uuid,

  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists oauth_pending_expiry_idx on public.oauth_pending (expires_at);

-- ----------------------------------------------------------------------------
-- Housekeeping. Extends 004's purge rather than adding a second schedule.
-- ----------------------------------------------------------------------------
create or replace function public.purge_expired_oauth() returns void
language sql security definer set search_path = public as $$
  delete from public.oauth_codes   where expires_at < now() - interval '1 day';
  delete from public.oauth_pending where expires_at < now() - interval '1 day';
  delete from public.oauth_tokens  where expires_at < now() - interval '7 days';
$$;

-- ----------------------------------------------------------------------------
-- Exposure. Service-role only, stated rather than assumed.
-- ----------------------------------------------------------------------------
alter table public.oauth_pending enable row level security;
revoke all on public.oauth_pending from anon, authenticated;
revoke all on function public.purge_expired_oauth() from anon, authenticated;
