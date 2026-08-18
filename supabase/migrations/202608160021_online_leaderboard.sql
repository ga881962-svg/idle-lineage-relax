-- Online-only leaderboard. A row is eligible only while its authenticated
-- account has a live game session and a server-bound current character.

alter table public.game_account_sessions
  add column if not exists active_character_id uuid references public.player_characters(id) on delete set null;

create index if not exists game_account_sessions_online_character_idx
  on public.game_account_sessions(active_character_id, expires_at desc)
  where invalidated_at is null and active_character_id is not null;

create or replace function public.online_leaderboard(p_session_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_rows jsonb;
begin
  perform public.assert_active_game_session(p_session_token);

  with online_characters as (
    select
      pc.id as character_id,
      pc.name,
      greatest(0, coalesce(case when (cp.state #>> '{p,lv}') ~ '^\\d+$' then (cp.state #>> '{p,lv}')::integer end, pc.level, 1)) as level,
      greatest(0, coalesce(case when (cp.state #>> '{p,gold}') ~ '^\\d+$' then (cp.state #>> '{p,gold}')::bigint end, 0)) as gold,
      greatest(0, coalesce(aw.sponsor_diamonds, 0)) as diamonds
    from public.game_account_sessions s
    join public.player_characters pc on pc.id = s.active_character_id and pc.user_id = s.user_id
    left join public.character_checkpoints cp on cp.character_id = pc.id
    left join public.account_wallets aw on aw.user_id = s.user_id
    where s.invalidated_at is null and s.expires_at > now()
  ), ranked as (
    select row_number() over (order by level desc, gold desc, diamonds desc, name asc) as rank,
           character_id, name, level, gold, diamonds
    from online_characters
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'rank', rank, 'characterId', character_id, 'name', name,
    'level', level, 'gold', gold, 'sponsorDiamonds', diamonds
  ) order by rank), '[]'::jsonb) into v_rows
  from ranked;

  return jsonb_build_object('players', v_rows, 'generatedAt', now());
end;
$$;

revoke all on function public.online_leaderboard(uuid) from public, anon;
grant execute on function public.online_leaderboard(uuid) to authenticated;
