-- ============================================================================
-- 004 — OAuth 2.1 + Dynamic Client Registration
--
-- The shared bearer made Spling a programmer's product: to use it you pasted a
-- 64-character secret into developer settings. The people this is built for
-- will not do that, and should not have to. These tables are what let a
-- "Sign in with Spling" button exist instead.
--
-- They also make the server multi-tenant, which the bearer never was: every
-- request resolved to one subject, so two people would have shared one
-- profile — including one person's allergens.
--
-- Nothing here is reachable with an anon or user key. Tokens are stored hashed
-- so that a leaked table is not a set of live sessions.
-- ============================================================================

create table if not exists public.oauth_clients (
  client_id text primary key,
  /* Only set for confidential clients; public clients (the assistants) use PKCE
     and register with no secret at all. Stored hashed regardless. */
  client_secret_hash text,
  client_name text not null default 'Unnamed client',
  redirect_uris text[] not null,
  grant_types text[] not null default array['authorization_code','refresh_token'],
  scope text not null default 'spling.order spling.profile spling.history',
  created_at timestamptz not null default now(),
  last_used_at timestamptz,

  constraint oauth_clients_has_redirect check (array_length(redirect_uris, 1) >= 1)
);

comment on table public.oauth_clients is
  'Dynamically registered clients (RFC 7591). An assistant registers itself here the first time a user connects.';

-- ----------------------------------------------------------------------------
-- Authorization codes. Single use, short lived, PKCE-bound.
-- ----------------------------------------------------------------------------
create table if not exists public.oauth_codes (
  code_hash text primary key,
  client_id text not null references public.oauth_clients(client_id) on delete cascade,
  subject uuid not null,
  redirect_uri text not null,
  scopes text[] not null,
  code_challenge text not null,
  code_challenge_method text not null default 'S256'
    check (code_challenge_method = 'S256'),   -- 'plain' is refused by design
  expires_at timestamptz not null,
  /* Set when redeemed. A code presented twice is an attack signal, not a retry:
     the handler revokes the whole grant when it sees one. */
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists oauth_codes_expiry_idx on public.oauth_codes (expires_at);

-- ----------------------------------------------------------------------------
-- Tokens. Access tokens are opaque and short lived; refresh tokens rotate on
-- every use, so a stolen refresh token stops working the moment the real client
-- uses theirs.
-- ----------------------------------------------------------------------------
create table if not exists public.oauth_tokens (
  token_hash text primary key,
  kind text not null check (kind in ('access','refresh')),
  client_id text not null references public.oauth_clients(client_id) on delete cascade,
  subject uuid not null,
  scopes text[] not null,
  /* Ties a refresh token to the family it was issued in, so revoking one
     revokes every descendant. */
  grant_id uuid not null,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists oauth_tokens_subject_idx on public.oauth_tokens (subject);
create index if not exists oauth_tokens_grant_idx on public.oauth_tokens (grant_id);
create index if not exists oauth_tokens_expiry_idx on public.oauth_tokens (expires_at) where revoked_at is null;

-- ----------------------------------------------------------------------------
-- Housekeeping. Expired codes and tokens are noise with a security cost;
-- call this from a scheduled function.
-- ----------------------------------------------------------------------------
create or replace function public.purge_expired_oauth() returns void
language sql security definer set search_path = public as $$
  delete from public.oauth_codes  where expires_at < now() - interval '1 day';
  delete from public.oauth_tokens where expires_at < now() - interval '7 days';
$$;

-- ----------------------------------------------------------------------------
-- Exposure. These tables are the keys to every profile on the server. They are
-- service-role only, stated rather than assumed — RLS with no policy denies
-- everything, and the revokes make that explicit to anyone reading the schema.
-- ----------------------------------------------------------------------------
alter table public.oauth_clients enable row level security;
alter table public.oauth_codes   enable row level security;
alter table public.oauth_tokens  enable row level security;

revoke all on public.oauth_clients from anon, authenticated;
revoke all on public.oauth_codes   from anon, authenticated;
revoke all on public.oauth_tokens  from anon, authenticated;
revoke all on function public.purge_expired_oauth() from anon, authenticated;
