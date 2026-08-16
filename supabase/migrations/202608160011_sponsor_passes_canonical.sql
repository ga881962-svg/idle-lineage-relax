-- Canonical 30-day EXP/GOLD/DROP sponsor passes.  Offline hunting is
-- deliberately excluded: it has not been rolled out as a purchasable feature.

create table if not exists public.sponsor_passes (
  user_id uuid not null references auth.users(id) on delete cascade,
  pass_kind text not null check (pass_kind in ('exp','gold','drop','offline')),
  expires_at timestamptz not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, pass_kind)
);

create table if not exists public.sponsor_pass_purchases (
  request_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  character_id uuid not null references public.player_characters(id) on delete cascade,
  pass_kind text not null check (pass_kind in ('exp','gold','drop','offline')),
  price_diamonds integer not null check (price_diamonds > 0),
  resulting_balance bigint not null,
  resulting_expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (user_id, request_id)
);

alter table public.sponsor_passes enable row level security;
alter table public.sponsor_pass_purchases enable row level security;
revoke all on public.sponsor_passes, public.sponsor_pass_purchases from public, anon, authenticated;

create or replace function public.sponsor_pass_status(
  p_session_token uuid, p_character_id uuid
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_passes jsonb; v_balance bigint := 0;
begin
  perform public.assert_active_game_session(p_session_token);
  if not exists (select 1 from public.player_characters pc where pc.id = p_character_id and pc.user_id = auth.uid()) then
    raise exception 'CHARACTER_NOT_FOUND';
  end if;
  select coalesce(jsonb_object_agg(sp.pass_kind, sp.expires_at), '{}'::jsonb)
    into v_passes from public.sponsor_passes sp where sp.user_id = auth.uid();
  select coalesce(aw.sponsor_diamonds, 0) into v_balance
    from public.account_wallets aw where aw.user_id = auth.uid();
  return jsonb_build_object('passes', coalesce(v_passes, '{}'::jsonb), 'sponsorDiamonds', v_balance);
end $$;

create or replace function public.sponsor_pass_purchase(
  p_session_token uuid, p_character_id uuid, p_pass_kind text, p_request_id uuid
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_exp timestamptz; v_balance bigint; v_replay_kind text;
begin
  perform public.assert_active_game_session(p_session_token);
  if p_pass_kind not in ('exp','gold','drop') then raise exception 'INVALID_PASS_KIND'; end if;
  if not exists (select 1 from public.player_characters pc where pc.id = p_character_id and pc.user_id = auth.uid()) then
    raise exception 'CHARACTER_NOT_FOUND';
  end if;
  select spp.pass_kind, spp.resulting_expires_at, spp.resulting_balance
    into v_replay_kind, v_exp, v_balance
    from public.sponsor_pass_purchases spp
    where spp.user_id = auth.uid() and spp.request_id = p_request_id;
  if found then
    if v_replay_kind <> p_pass_kind then raise exception 'REQUEST_ID_PAYLOAD_MISMATCH'; end if;
    return jsonb_build_object('kind', p_pass_kind, 'expiresAt', v_exp, 'sponsorDiamonds', v_balance, 'replayed', true);
  end if;
  insert into public.account_wallets(user_id, sponsor_diamonds) values(auth.uid(), 0) on conflict(user_id) do nothing;
  select aw.sponsor_diamonds into v_balance from public.account_wallets aw where aw.user_id = auth.uid() for update;
  if coalesce(v_balance, 0) < 199 then raise exception 'INSUFFICIENT_SPONSOR_DIAMONDS'; end if;
  update public.account_wallets aw set sponsor_diamonds = aw.sponsor_diamonds - 199, updated_at = now()
    where aw.user_id = auth.uid() returning aw.sponsor_diamonds into v_balance;
  insert into public.sponsor_passes(user_id, pass_kind, expires_at) values(auth.uid(), p_pass_kind, now() + interval '30 days')
    on conflict(user_id, pass_kind) do update set expires_at = greatest(public.sponsor_passes.expires_at, now()) + interval '30 days', updated_at = now()
    returning expires_at into v_exp;
  insert into public.sponsor_pass_purchases(request_id, user_id, character_id, pass_kind, price_diamonds, resulting_balance, resulting_expires_at)
    values(p_request_id, auth.uid(), p_character_id, p_pass_kind, 199, v_balance, v_exp);
  return jsonb_build_object('kind', p_pass_kind, 'expiresAt', v_exp, 'sponsorDiamonds', v_balance);
end $$;

revoke all on function public.sponsor_pass_status(uuid, uuid), public.sponsor_pass_purchase(uuid, uuid, text, uuid) from public, anon;
grant execute on function public.sponsor_pass_status(uuid, uuid), public.sponsor_pass_purchase(uuid, uuid, text, uuid) to authenticated;
