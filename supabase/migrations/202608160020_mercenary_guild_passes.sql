-- Canonical Mercenary Guild Pass.  This entitlement is intentionally separate
-- from sponsor_passes (EXP/GOLD/DROP) and the Offline Hunt pass.

create table if not exists public.mercenary_guild_passes (
  user_id uuid primary key references auth.users(id) on delete cascade,
  expires_at timestamptz not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.mercenary_guild_pass_purchases (
  request_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  character_id uuid not null references public.player_characters(id) on delete cascade,
  price_diamonds integer not null check (price_diamonds = 599),
  resulting_balance bigint not null,
  resulting_expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (user_id, request_id)
);

create index if not exists mercenary_guild_pass_purchases_user_created_idx
  on public.mercenary_guild_pass_purchases(user_id, created_at desc);

alter table public.mercenary_guild_passes enable row level security;
alter table public.mercenary_guild_pass_purchases enable row level security;
revoke all on public.mercenary_guild_passes, public.mercenary_guild_pass_purchases from public, anon, authenticated;

create or replace function public.mercenary_guild_pass_status(
  p_session_token uuid, p_character_id uuid
) returns jsonb language plpgsql security definer set search_path = public, pg_catalog as $$
declare v_expires_at timestamptz; v_balance bigint := 0;
begin
  perform public.assert_active_game_session(p_session_token);
  if not exists (select 1 from public.player_characters pc where pc.id = p_character_id and pc.user_id = auth.uid()) then
    raise exception 'CHARACTER_NOT_FOUND';
  end if;
  select mgp.expires_at into v_expires_at from public.mercenary_guild_passes mgp where mgp.user_id = auth.uid();
  select coalesce(aw.sponsor_diamonds, 0) into v_balance from public.account_wallets aw where aw.user_id = auth.uid();
  return jsonb_build_object('expiresAt', v_expires_at, 'active', coalesce(v_expires_at > now(), false), 'sponsorDiamonds', v_balance);
end $$;

create or replace function public.mercenary_guild_pass_purchase(
  p_session_token uuid, p_character_id uuid, p_request_id uuid
) returns jsonb language plpgsql security definer set search_path = public, pg_catalog as $$
declare v_expires_at timestamptz; v_balance bigint; v_replay public.mercenary_guild_pass_purchases%rowtype;
begin
  perform public.assert_active_game_session(p_session_token);
  if not exists (select 1 from public.player_characters pc where pc.id = p_character_id and pc.user_id = auth.uid()) then
    raise exception 'CHARACTER_NOT_FOUND';
  end if;
  select * into v_replay from public.mercenary_guild_pass_purchases p where p.user_id = auth.uid() and p.request_id = p_request_id;
  if found then
    return jsonb_build_object('expiresAt', v_replay.resulting_expires_at, 'active', v_replay.resulting_expires_at > now(), 'sponsorDiamonds', v_replay.resulting_balance, 'replayed', true);
  end if;
  insert into public.account_wallets(user_id, sponsor_diamonds) values(auth.uid(), 0) on conflict(user_id) do nothing;
  select aw.sponsor_diamonds into v_balance from public.account_wallets aw where aw.user_id = auth.uid() for update;
  -- Recheck after the wallet lock so concurrent retries cannot debit twice.
  select * into v_replay from public.mercenary_guild_pass_purchases p where p.user_id = auth.uid() and p.request_id = p_request_id;
  if found then
    return jsonb_build_object('expiresAt', v_replay.resulting_expires_at, 'active', v_replay.resulting_expires_at > now(), 'sponsorDiamonds', v_replay.resulting_balance, 'replayed', true);
  end if;
  if coalesce(v_balance, 0) < 599 then raise exception 'INSUFFICIENT_SPONSOR_DIAMONDS'; end if;
  update public.account_wallets aw set sponsor_diamonds = aw.sponsor_diamonds - 599, updated_at = now()
    where aw.user_id = auth.uid() returning aw.sponsor_diamonds into v_balance;
  insert into public.mercenary_guild_passes(user_id, expires_at) values(auth.uid(), now() + interval '30 days')
    on conflict(user_id) do update set expires_at = greatest(public.mercenary_guild_passes.expires_at, now()) + interval '30 days', updated_at = now()
    returning expires_at into v_expires_at;
  insert into public.mercenary_guild_pass_purchases(request_id, user_id, character_id, price_diamonds, resulting_balance, resulting_expires_at)
    values(p_request_id, auth.uid(), p_character_id, 599, v_balance, v_expires_at);
  return jsonb_build_object('expiresAt', v_expires_at, 'active', true, 'sponsorDiamonds', v_balance, 'replayed', false);
end $$;

-- A summon must obtain a fresh server authorization.  It is deliberately a
-- separate read-only gate: no client price, expiry or entitlement is trusted.
create or replace function public.mercenary_guild_summon_authorize(
  p_session_token uuid, p_character_id uuid
) returns jsonb language plpgsql security definer set search_path = public, pg_catalog as $$
declare v_expires_at timestamptz;
begin
  perform public.assert_active_game_session(p_session_token);
  if not exists (select 1 from public.player_characters pc where pc.id = p_character_id and pc.user_id = auth.uid()) then
    raise exception 'CHARACTER_NOT_FOUND';
  end if;
  select mgp.expires_at into v_expires_at from public.mercenary_guild_passes mgp where mgp.user_id = auth.uid() for share;
  if v_expires_at is null or v_expires_at <= now() then raise exception 'MERCENARY_GUILD_PASS_REQUIRED'; end if;
  return jsonb_build_object('allowed', true, 'expiresAt', v_expires_at);
end $$;

revoke all on function public.mercenary_guild_pass_status(uuid, uuid), public.mercenary_guild_pass_purchase(uuid, uuid, uuid), public.mercenary_guild_summon_authorize(uuid, uuid) from public, anon;
grant execute on function public.mercenary_guild_pass_status(uuid, uuid), public.mercenary_guild_pass_purchase(uuid, uuid, uuid), public.mercenary_guild_summon_authorize(uuid, uuid) to authenticated;
