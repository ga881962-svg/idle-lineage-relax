-- Test-project-only prerequisite schema for Phase 0 integration verification.
-- This is intentionally minimal: it is not a production migration and must
-- never be placed under supabase/migrations or run against production.
create extension if not exists pgcrypto;

create table if not exists public.player_characters (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  slot smallint not null check (slot between 1 and 8),
  name text not null check (char_length(name) between 1 and 20),
  class_id text not null,
  level smallint not null default 1 check (level between 1 and 99),
  state jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, slot)
);

create table if not exists public.character_checkpoints (
  character_id uuid primary key references public.player_characters(id) on delete cascade,
  revision bigint not null default 0 check (revision >= 0),
  state jsonb not null default '{}'::jsonb,
  issued_at timestamptz not null default now(),
  saved_at timestamptz not null default now()
);

create table if not exists public.game_account_sessions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  session_token uuid not null default gen_random_uuid(),
  device_id uuid not null,
  ip_hash text,
  issued_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '15 minutes'),
  invalidated_at timestamptz,
  created_at timestamptz not null default now()
);

create or replace function public.assert_active_game_session(p_session_token uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'SESSION_REQUIRED'; end if;
  perform 1 from public.game_account_sessions s
  where s.user_id=auth.uid() and s.session_token=p_session_token
    and s.invalidated_at is null and s.expires_at>now()
  for key share;
  if not found then raise exception 'SESSION_REPLACED'; end if;
end $$;
revoke all on function public.assert_active_game_session(uuid) from public;
