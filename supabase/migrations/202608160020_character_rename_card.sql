-- Canonical character rename card: one server-authoritative rename costs 200
-- sponsor diamonds.  This does not alter sponsor pass semantics.

create table if not exists public.character_rename_requests (
  request_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  character_id uuid not null references public.player_characters(id) on delete cascade,
  requested_name text not null,
  resulting_balance bigint not null,
  resulting_revision bigint,
  created_at timestamptz not null default now(),
  unique (user_id, request_id)
);

create index if not exists character_rename_requests_character_created_idx
  on public.character_rename_requests(character_id, created_at desc);

alter table public.character_rename_requests enable row level security;
revoke all on public.character_rename_requests from public, anon, authenticated;

create or replace function public.character_rename(
  p_session_token uuid,
  p_character_id uuid,
  p_new_name text,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_name text := btrim(coalesce(p_new_name, ''));
  v_name_key text;
  v_current_name text;
  v_balance bigint;
  v_revision bigint;
  v_replay public.character_rename_requests%rowtype;
begin
  perform public.assert_active_game_session(p_session_token);
  if p_request_id is null then raise exception 'INVALID_REQUEST_ID'; end if;
  if char_length(v_name) < 1 or char_length(v_name) > 20
     or v_name ~ '[[:cntrl:]]' or v_name ~ '[<>&"'']' then
    raise exception 'INVALID_CHARACTER_NAME';
  end if;
  v_name_key := lower(v_name);

  -- Replays of one request must wait for the first transaction to commit;
  -- otherwise a concurrent retry could race the purchase ledger.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_request_id::text, 0));

  select * into v_replay from public.character_rename_requests
   where user_id = auth.uid() and request_id = p_request_id;
  if found then
    if v_replay.character_id <> p_character_id or lower(v_replay.requested_name) <> v_name_key then
      raise exception 'REQUEST_ID_PAYLOAD_MISMATCH';
    end if;
    return jsonb_build_object('name', v_replay.requested_name, 'sponsorDiamonds', v_replay.resulting_balance, 'revision', v_replay.resulting_revision, 'replayed', true);
  end if;

  -- Serialize concurrent requests for the same display name.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_name_key, 0));
  select pc.name into v_current_name from public.player_characters pc
   where pc.id = p_character_id and pc.user_id = auth.uid() for update;
  if not found then raise exception 'CHARACTER_NOT_FOUND'; end if;
  if lower(btrim(v_current_name)) = v_name_key then raise exception 'CHARACTER_NAME_UNCHANGED'; end if;
  if exists (select 1 from public.player_characters pc where pc.id <> p_character_id and lower(btrim(pc.name)) = v_name_key) then
    raise exception 'CHARACTER_NAME_TAKEN';
  end if;

  insert into public.account_wallets(user_id, sponsor_diamonds) values (auth.uid(), 0) on conflict (user_id) do nothing;
  select aw.sponsor_diamonds into v_balance from public.account_wallets aw where aw.user_id = auth.uid() for update;
  if coalesce(v_balance, 0) < 200 then raise exception 'INSUFFICIENT_SPONSOR_DIAMONDS'; end if;
  update public.account_wallets aw set sponsor_diamonds = aw.sponsor_diamonds - 200, updated_at = now()
   where aw.user_id = auth.uid() returning aw.sponsor_diamonds into v_balance;

  update public.player_characters pc set name = v_name, updated_at = now() where pc.id = p_character_id;
  -- Cloud play restores this checkpoint. Bump its revision so stale saves cannot restore the prior name.
  update public.character_checkpoints as cp
     set state = jsonb_set(coalesce(cp.state, '{}'::jsonb), '{p,name}', to_jsonb(v_name), true),
         revision = cp.revision + 1, saved_at = now()
   where cp.character_id = p_character_id returning cp.revision into v_revision;

  insert into public.character_rename_requests(request_id, user_id, character_id, requested_name, resulting_balance, resulting_revision)
    values (p_request_id, auth.uid(), p_character_id, v_name, v_balance, v_revision);
  return jsonb_build_object('name', v_name, 'sponsorDiamonds', v_balance, 'revision', v_revision, 'replayed', false);
end $$;

revoke all on function public.character_rename(uuid, uuid, text, uuid) from public, anon;
grant execute on function public.character_rename(uuid, uuid, text, uuid) to authenticated;
