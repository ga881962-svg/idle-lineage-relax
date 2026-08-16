-- Server-authoritative offline hunting and the 30-day offline pass.
-- This migration is intentionally not applied automatically.

create table if not exists public.offline_hunt_passes (
  user_id uuid primary key references auth.users(id) on delete cascade,
  expires_at timestamptz not null,
  updated_at timestamptz not null default now()
);

-- All four sponsor passes are server-owned.  The legacy offline table remains
-- during rollout so existing callers keep working, but `sponsor_passes` is the
-- sole authority for snapshots and expiry boundaries.
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

create table if not exists public.offline_hunt_pass_purchases (
  request_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  character_id uuid not null references public.player_characters(id) on delete cascade,
  price_diamonds integer not null check (price_diamonds > 0),
  resulting_balance bigint not null,
  resulting_expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (user_id, request_id)
);

create table if not exists public.offline_hunt_departures (
  character_id uuid primary key references public.player_characters(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  map_id text not null,
  armed_at timestamptz not null,
  pass_expires_at timestamptz not null,
  checkpoint_revision bigint not null,
  verified_kills_per_second numeric(12,6),
  verified_sample_kills integer not null default 0,
  verified_sampled_at timestamptz,
  catalog_sha256 text,
  combat_snapshot jsonb not null default '{}'::jsonb,
  snapshot_sha256 text,
  status text not null default 'armed' check (status in ('armed','disarmed','settled')),
  disarmed_at timestamptz,
  disarm_reason text,
  updated_at timestamptz not null default now()
);

create table if not exists public.offline_hunt_kill_events (
  request_id uuid primary key,
  character_id uuid not null references public.player_characters(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  map_id text not null,
  mob_id text not null,
  killed_at timestamptz not null default now(),
  unique(user_id, request_id)
);
create index if not exists offline_hunt_kill_events_sample_idx
  on public.offline_hunt_kill_events(character_id, map_id, killed_at desc);

create table if not exists public.offline_hunt_settlements (
  id uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.player_characters(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  request_id uuid not null,
  map_id text not null,
  offline_seconds integer not null,
  effective_seconds integer not null,
  rewards jsonb not null default '{}'::jsonb,
  resulting_revision bigint not null,
  resulting_state jsonb not null,
  return_allowed boolean not null default true,
  created_at timestamptz not null default now(),
  acknowledged_at timestamptz,
  unique (user_id, request_id)
);

alter table public.offline_hunt_passes enable row level security;
alter table public.offline_hunt_pass_purchases enable row level security;
alter table public.offline_hunt_departures enable row level security;
alter table public.offline_hunt_settlements enable row level security;
alter table public.offline_hunt_kill_events enable row level security;
alter table public.sponsor_passes enable row level security;
alter table public.sponsor_pass_purchases enable row level security;
revoke all on public.offline_hunt_passes, public.offline_hunt_pass_purchases, public.offline_hunt_departures, public.offline_hunt_settlements, public.offline_hunt_kill_events, public.sponsor_passes, public.sponsor_pass_purchases from anon, authenticated;

create or replace function public.sponsor_pass_status(
  p_session_token uuid, p_character_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_passes jsonb; v_balance bigint:=0;
begin
  perform public.assert_active_game_session(p_session_token);
  if not exists(select 1 from public.player_characters pc where pc.id=p_character_id and pc.user_id=auth.uid()) then raise exception 'CHARACTER_NOT_FOUND'; end if;
  select coalesce(jsonb_object_agg(sp.pass_kind,sp.expires_at),'{}'::jsonb) into v_passes from public.sponsor_passes sp where sp.user_id=auth.uid();
  select coalesce(aw.sponsor_diamonds,0) into v_balance from public.account_wallets aw where aw.user_id=auth.uid();
  return jsonb_build_object('passes',coalesce(v_passes,'{}'::jsonb),'sponsorDiamonds',v_balance);
end $$;

create or replace function public.sponsor_pass_purchase(
  p_session_token uuid, p_character_id uuid, p_pass_kind text, p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_price integer; v_exp timestamptz; v_balance bigint;
begin
  perform public.assert_active_game_session(p_session_token);
  if p_pass_kind not in ('exp','gold','drop','offline') then raise exception 'INVALID_PASS_KIND'; end if;
  if not exists(select 1 from public.player_characters pc where pc.id=p_character_id and pc.user_id=auth.uid()) then raise exception 'CHARACTER_NOT_FOUND'; end if;
  v_price:=case p_pass_kind when 'offline' then 599 else 199 end;
  select spp.resulting_expires_at,spp.resulting_balance into v_exp,v_balance from public.sponsor_pass_purchases spp where spp.user_id=auth.uid() and spp.request_id=p_request_id;
  if found then return jsonb_build_object('kind',p_pass_kind,'expiresAt',v_exp,'sponsorDiamonds',v_balance,'replayed',true); end if;
  insert into public.account_wallets(user_id,sponsor_diamonds) values(auth.uid(),0) on conflict(user_id) do nothing;
  select aw.sponsor_diamonds into v_balance from public.account_wallets aw where aw.user_id=auth.uid() for update;
  if coalesce(v_balance,0)<v_price then raise exception 'INSUFFICIENT_SPONSOR_DIAMONDS'; end if;
  update public.account_wallets aw set sponsor_diamonds=aw.sponsor_diamonds-v_price,updated_at=now() where aw.user_id=auth.uid() returning aw.sponsor_diamonds into v_balance;
  insert into public.sponsor_passes(user_id,pass_kind,expires_at) values(auth.uid(),p_pass_kind,now()+interval '30 days')
  on conflict(user_id,pass_kind) do update set expires_at=greatest(public.sponsor_passes.expires_at,now())+interval '30 days',updated_at=now()
  returning expires_at into v_exp;
  if p_pass_kind='offline' then
    insert into public.offline_hunt_passes(user_id,expires_at) values(auth.uid(),v_exp) on conflict(user_id) do update set expires_at=excluded.expires_at,updated_at=now();
  end if;
  insert into public.sponsor_pass_purchases(request_id,user_id,character_id,pass_kind,price_diamonds,resulting_balance,resulting_expires_at) values(p_request_id,auth.uid(),p_character_id,p_pass_kind,v_price,v_balance,v_exp);
  return jsonb_build_object('kind',p_pass_kind,'expiresAt',v_exp,'sponsorDiamonds',v_balance);
end $$;

create or replace function public.offline_hunt_build_snapshot(p_character_id uuid,p_state jsonb,p_map_id text,p_catalog_sha256 text)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_player jsonb:=coalesce(p_state->'p','{}'::jsonb); v_doll text:=p_state#>>'{p,eq,doll,id}'; v_allies integer:=0; v_exp_bonus numeric:=0; v_gold_bonus numeric:=0; v_relic_x2 boolean:=false; v_skills jsonb; v_passes jsonb; v_inventory jsonb; v_allied_quests jsonb; v_warehouse jsonb; v_mode_bucket text;
begin
  if coalesce(v_player->>'cls','') not in ('royal','knight','elf','mage','dark','dragon','illusion','warrior') then raise exception 'INVALID_CHARACTER_CLASS'; end if;
  select count(*) into v_allies from jsonb_array_elements(coalesce(v_player->'allies','[]'::jsonb)) a where coalesce((a.value->>'_downed')::boolean,false)=false;
  v_allies:=least(7,greatest(0,v_allies));
  select coalesce(iec.exp_bonus,0),coalesce(iec.gold_bonus,0) into v_exp_bonus,v_gold_bonus from public.offline_hunt_item_effect_catalog iec where iec.item_id=v_doll and iec.is_doll;
  select exists(select 1 from jsonb_each(coalesce(v_player->'eq','{}'::jsonb)) e join public.offline_hunt_item_effect_catalog iec on iec.item_id=e.value->>'id' where iec.relic_drop_x2) into v_relic_x2;
  select coalesce(jsonb_agg(to_jsonb(s.value)),'[]'::jsonb) into v_skills from jsonb_array_elements_text(coalesce(v_player->'skills','[]'::jsonb)) s(value) join public.offline_hunt_skill_catalog sc on sc.skill_id=s.value;
  select coalesce(jsonb_object_agg(sp.pass_kind,sp.expires_at),'{}'::jsonb) into v_passes from public.sponsor_passes sp where sp.user_id=auth.uid();
  v_mode_bucket:=case when coalesce((v_player->>'classicMode')::boolean,false) then 'classic' else 'normal' end;
  -- Defined in 202608160002. This server-side aggregate deliberately replaces
  -- the old browser/localStorage `whCountId()` input for departure snapshots.
  select public.offline_hunt_warehouse_counts(auth.uid(),v_mode_bucket) into v_warehouse;
  -- Preserve aggregate counts, including locked items.  Stage-50 checks use
  -- total held; normal trial checks use only unlocked held.  Never expose or
  -- reconstruct individual item instances during settlement.
  select coalesce(jsonb_object_agg(item_id,jsonb_build_object('total',total,'unlocked',unlocked,'locked',total-unlocked)),'{}'::jsonb) into v_inventory
  from (select i.value->>'id' item_id, sum(greatest(0,coalesce((i.value->>'cnt')::integer,1))) total, sum(case when coalesce((i.value->>'lock')::boolean,false) then 0 else greatest(0,coalesce((i.value->>'cnt')::integer,1)) end) unlocked from jsonb_array_elements(coalesce(v_player->'inv','[]'::jsonb)) i(value) where coalesce(i.value->>'id','')<>'' group by i.value->>'id') inventory;
  -- `_questLoot` is the online pending ledger for allies.  It is copied with
  -- the ally's class/stage/inventory so an offline interval cannot award the
  -- same trial item twice after the party is restored.
  select coalesce(jsonb_agg(jsonb_build_object('slot',a.value->>'_slot','class',a.value->>'cls','level',coalesce((a.value->>'lv')::integer,1),'downed',coalesce((a.value->>'_downed')::boolean,false),'trialQ',coalesce(a.value->'trialQ','{}'::jsonb),'trialStage',coalesce(a.value->'trialStage','0'::jsonb),'pendingQuestLoot',coalesce(a.value->'_questLoot','{}'::jsonb),'inventory',coalesce((select jsonb_object_agg(item_id,jsonb_build_object('total',total,'unlocked',unlocked,'locked',total-unlocked)) from (select ai.value->>'id' item_id, sum(greatest(0,coalesce((ai.value->>'cnt')::integer,1))) total, sum(case when coalesce((ai.value->>'lock')::boolean,false) then 0 else greatest(0,coalesce((ai.value->>'cnt')::integer,1)) end) unlocked from jsonb_array_elements(coalesce(a.value->'inv','[]'::jsonb)) ai(value) where coalesce(ai.value->>'id','')<>'' group by ai.value->>'id') ally_inventory),'{}'::jsonb)))),'[]'::jsonb) into v_allied_quests from jsonb_array_elements(coalesce(v_player->'allies','[]'::jsonb)) a(value);
  return jsonb_build_object('characterId',p_character_id,'level',least(100,greatest(1,coalesce((v_player->>'lv')::integer,1))),'class',v_player->>'cls','mapId',p_map_id,'catalogHash',p_catalog_sha256,'offlinePassExpiresAt',v_passes->'offline','expPassExpiresAt',v_passes->'exp','goldPassExpiresAt',v_passes->'gold','dropPassExpiresAt',v_passes->'drop','party',jsonb_build_object('activeAllies',v_allies,'rewardMultiplier',v_allies+1,'expBonusPct',v_allies*(case when v_player->>'cls'='royal' then 8 else 4 end),'allies',v_allied_quests),'doll',jsonb_build_object('itemId',v_doll,'expBonusPct',v_exp_bonus,'goldBonusPct',v_gold_bonus),'relic',jsonb_build_object('dropX2',v_relic_x2),'skills',v_skills,'questState',jsonb_build_object('trialQ',coalesce(v_player->'trialQ','{}'::jsonb),'trialStage',coalesce(v_player->'trialStage','0'::jsonb),'masteryQuest',coalesce(v_player->'masteryQuest','null'::jsonb),'flameAffinity',coalesce(v_player->'flameAffinity','0'::jsonb),'inventory',v_inventory,'warehouseCounts',coalesce(v_warehouse,'{}'::jsonb),'warehouseAuthoritative',true));
end $$;

create or replace function public.offline_hunt_status(
  p_session_token uuid, p_character_id uuid
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_exp timestamptz; v_balance bigint := 0;
begin
  perform public.assert_active_game_session(p_session_token);
  if not exists(select 1 from public.player_characters pc where pc.id=p_character_id and pc.user_id=auth.uid()) then raise exception 'CHARACTER_NOT_FOUND'; end if;
  select sp.expires_at into v_exp from public.sponsor_passes sp where sp.user_id=auth.uid() and sp.pass_kind='offline';
  select coalesce(aw.sponsor_diamonds,0) into v_balance from public.account_wallets aw where aw.user_id=auth.uid();
  return jsonb_build_object('active',coalesce(v_exp>now(),false),'expiresAt',v_exp,'sponsorDiamonds',v_balance);
end $$;

create or replace function public.offline_hunt_purchase_pass(
  p_session_token uuid, p_character_id uuid, p_request_id uuid
) returns jsonb language sql security definer set search_path = public as $$
  select public.sponsor_pass_purchase(p_session_token,p_character_id,'offline',p_request_id)
$$;

create or replace function public.offline_hunt_arm(
  p_session_token uuid, p_character_id uuid, p_map_id text, p_request_id uuid
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_exp timestamptz; v_rev bigint; v_state jsonb; v_saved timestamptz; v_catalog text; v_snapshot jsonb;
begin
  perform public.assert_active_game_session(p_session_token);
  if p_map_id is null or p_map_id='' or left(p_map_id,5)='town_' then raise exception 'INVALID_COMBAT_MAP'; end if;
  if not exists(select 1 from public.player_characters pc where pc.id=p_character_id and pc.user_id=auth.uid()) then raise exception 'CHARACTER_NOT_FOUND'; end if;
  select sp.expires_at into v_exp from public.sponsor_passes sp where sp.user_id=auth.uid() and sp.pass_kind='offline' and sp.expires_at>now();
  if v_exp is null then raise exception 'OFFLINE_PASS_REQUIRED'; end if;
  select cc.revision,cc.state,cc.saved_at into v_rev,v_state,v_saved from public.character_checkpoints cc where cc.character_id=p_character_id for update;
  if v_state is null or now()-v_saved>interval '2 minutes' then raise exception 'RECENT_CHECKPOINT_REQUIRED'; end if;
  if coalesce(v_state#>>'{ms,current}','')<>p_map_id and coalesce(v_state#>>'{mapState,current}','')<>p_map_id then raise exception 'MAP_STATE_MISMATCH'; end if;
  select cm.source_sha256 into v_catalog from public.offline_hunt_catalog_meta cm where cm.singleton=true;
  if v_catalog is null then raise exception 'OFFLINE_CATALOG_UNAVAILABLE'; end if;
  v_snapshot:=public.offline_hunt_build_snapshot(p_character_id,v_state,p_map_id,v_catalog);
  insert into public.offline_hunt_departures(character_id,user_id,map_id,armed_at,pass_expires_at,checkpoint_revision,catalog_sha256,combat_snapshot,snapshot_sha256,status,updated_at)
  values(p_character_id,auth.uid(),p_map_id,now(),v_exp,v_rev,v_catalog,v_snapshot,encode(digest(v_snapshot::text,'sha256'),'hex'),'armed',now())
  on conflict(character_id) do update set
    user_id=excluded.user_id,map_id=excluded.map_id,armed_at=excluded.armed_at,
    pass_expires_at=excluded.pass_expires_at,checkpoint_revision=excluded.checkpoint_revision,combat_snapshot=excluded.combat_snapshot,snapshot_sha256=excluded.snapshot_sha256,
    status='armed',disarmed_at=null,disarm_reason=null,
    verified_kills_per_second=case
      when public.offline_hunt_departures.map_id=excluded.map_id
       and public.offline_hunt_departures.verified_sampled_at>=now()-interval '5 minutes'
      then public.offline_hunt_departures.verified_kills_per_second else null end,
    verified_sample_kills=case
      when public.offline_hunt_departures.map_id=excluded.map_id
       and public.offline_hunt_departures.verified_sampled_at>=now()-interval '5 minutes'
      then public.offline_hunt_departures.verified_sample_kills else 0 end,
    verified_sampled_at=case
      when public.offline_hunt_departures.map_id=excluded.map_id
       and public.offline_hunt_departures.verified_sampled_at>=now()-interval '5 minutes'
      then public.offline_hunt_departures.verified_sampled_at else null end,
    catalog_sha256=case
      when public.offline_hunt_departures.map_id=excluded.map_id
       and public.offline_hunt_departures.verified_sampled_at>=now()-interval '5 minutes'
      then public.offline_hunt_departures.catalog_sha256 else null end,
    updated_at=now();
  return jsonb_build_object('armed',true,'mapId',p_map_id,'passExpiresAt',v_exp);
end $$;

create or replace function public.offline_hunt_record_kill(
  p_session_token uuid, p_character_id uuid, p_map_id text, p_mob_id text, p_request_id uuid
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_last timestamptz; v_first timestamptz; v_count integer; v_rate numeric; v_hash text;
begin
  perform public.assert_active_game_session(p_session_token);
  if not exists(select 1 from public.player_characters pc where pc.id=p_character_id and pc.user_id=auth.uid()) then raise exception 'CHARACTER_NOT_FOUND'; end if;
  if not exists(select 1 from public.offline_hunt_map_catalog mc where mc.map_id=p_map_id and mc.mob_id=p_mob_id) then raise exception 'INVALID_MAP_MONSTER'; end if;
  if not exists(select 1 from public.offline_hunt_passes hp where hp.user_id=auth.uid() and hp.expires_at>now()) then return jsonb_build_object('recorded',false,'reason','OFFLINE_PASS_INACTIVE'); end if;
  select ke.killed_at into v_last from public.offline_hunt_kill_events ke where ke.character_id=p_character_id order by ke.killed_at desc limit 1;
  if v_last is not null and now()-v_last<interval '250 milliseconds' then raise exception 'KILL_RATE_LIMIT'; end if;
  insert into public.offline_hunt_kill_events(request_id,character_id,user_id,map_id,mob_id)
    values(p_request_id,p_character_id,auth.uid(),p_map_id,p_mob_id) on conflict(request_id) do nothing;
  select min(ke.killed_at),count(*)::integer into v_first,v_count
    from public.offline_hunt_kill_events ke
    where ke.character_id=p_character_id and ke.map_id=p_map_id and ke.killed_at>=now()-interval '5 minutes';
  if v_count>=5 then
    v_rate:=least(4.0,(v_count-1)/greatest(1,extract(epoch from (now()-v_first))));
    select cm.source_sha256 into v_hash from public.offline_hunt_catalog_meta cm where cm.singleton=true;
    update public.offline_hunt_departures d set armed_at=now(),verified_kills_per_second=v_rate,
      verified_sample_kills=v_count,verified_sampled_at=now(),catalog_sha256=v_hash,updated_at=now()
      where d.character_id=p_character_id and d.user_id=auth.uid() and d.map_id=p_map_id and d.status='armed';
  end if;
  delete from public.offline_hunt_kill_events ke where ke.character_id=p_character_id and ke.killed_at<now()-interval '20 minutes';
  return jsonb_build_object('recorded',true,'sampleKills',v_count,'killsPerSecond',v_rate);
end $$;

create or replace function public.offline_hunt_disarm(
  p_session_token uuid, p_character_id uuid, p_reason text default 'not_in_combat'
) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_active_game_session(p_session_token);
  update public.offline_hunt_departures d set status='disarmed',disarmed_at=now(),disarm_reason=left(coalesce(p_reason,'not_in_combat'),80),updated_at=now()
  where d.character_id=p_character_id and d.user_id=auth.uid() and d.status='armed';
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.offline_hunt_settle(
  p_session_token uuid, p_character_id uuid, p_request_id uuid
) returns jsonb language plpgsql security definer set search_path = public as $$
declare d public.offline_hunt_departures%rowtype; cc public.character_checkpoints%rowtype; v_now timestamptz:=now();
declare v_off integer; v_eff integer; v_kills bigint; v_exp bigint:=0; v_gold bigint:=0; v_state jsonb; v_rewards jsonb:='{}'::jsonb; v_result_state jsonb; v_rev bigint; v_id uuid; v_return boolean; r_mob record; r_drop record; r_item record; v_count bigint; v_expected numeric;
begin
  perform public.assert_active_game_session(p_session_token);
  if not exists(select 1 from public.player_characters pc where pc.id=p_character_id and pc.user_id=auth.uid()) then raise exception 'CHARACTER_NOT_FOUND'; end if;
  select * into d from public.offline_hunt_departures x where x.character_id=p_character_id and x.user_id=auth.uid() for update;
  if not found or d.status<>'armed' then
    select s.id,s.offline_seconds,s.effective_seconds,s.rewards,s.resulting_revision,s.resulting_state,s.return_allowed
      into v_id,v_off,v_eff,v_rewards,v_rev,v_result_state,v_return from public.offline_hunt_settlements s
      where s.character_id=p_character_id and s.user_id=auth.uid() and s.acknowledged_at is null order by s.created_at desc limit 1;
    if v_id is null then return jsonb_build_object('settled',false); end if;
    return jsonb_build_object('settled',true,'settlementId',v_id,'offlineSeconds',v_off,'effectiveSeconds',v_eff,'rewards',v_rewards,'revision',v_rev,'state',v_result_state,'returnBlocked',not v_return);
  end if;
  select * into cc from public.character_checkpoints x where x.character_id=p_character_id for update;
  if cc.state is null then raise exception 'CHECKPOINT_NOT_FOUND'; end if;
  if coalesce(cc.state#>>'{ms,current}','')<>d.map_id and coalesce(cc.state#>>'{mapState,current}','')<>d.map_id then raise exception 'MAP_STATE_MISMATCH'; end if;
  v_off:=greatest(0,extract(epoch from (v_now-d.armed_at))::integer);
  v_eff:=greatest(0,least(v_off,43200,extract(epoch from (least(v_now,d.pass_expires_at)-d.armed_at))::integer));
  if d.verified_kills_per_second is null or d.verified_sample_kills<5 or d.verified_sampled_at<d.armed_at-interval '10 minutes' then raise exception 'VERIFIED_COMBAT_SAMPLE_REQUIRED'; end if;
  if d.catalog_sha256 is distinct from (select cm.source_sha256 from public.offline_hunt_catalog_meta cm where cm.singleton=true) then raise exception 'OFFLINE_CATALOG_CHANGED'; end if;
  v_kills:=floor(v_eff*d.verified_kills_per_second);
  -- Prefer the composition of the player's server-timestamped online kill
  -- sample.  The map pool is only a defensive fallback for old rows; the
  -- browser never supplies reward rates or results.
  for r_mob in
    with sampled as (
      select ke.mob_id,count(*)::numeric as weight
      from public.offline_hunt_kill_events ke
      where ke.character_id=p_character_id and ke.map_id=d.map_id
        and ke.killed_at>=d.verified_sampled_at-interval '5 minutes'
        and ke.killed_at<=d.verified_sampled_at
      group by ke.mob_id
    ), pool as (
      select s.mob_id,s.weight from sampled s
      union all
      select mc.mob_id,mc.weight::numeric
      from public.offline_hunt_map_catalog mc
      where mc.map_id=d.map_id and not exists(select 1 from sampled)
    ), weighted as (
      select p.mob_id,p.weight,sum(p.weight) over() total_weight from pool p
    )
    select p.mob_id,om.level,om.exp,om.gold_min,om.gold_max,om.boss,(v_kills*p.weight/p.total_weight)::bigint as kills
      from weighted p join public.offline_hunt_mob_catalog om on om.mob_id=p.mob_id
  loop
    v_exp:=v_exp+r_mob.kills*r_mob.exp;
    -- Same base expectation as online monsterGoldRange(): bosses keep their
    -- configured range; ordinary monsters use the level curve and drop gold
    -- on 70% of kills.  Online's final -10%..+10% roll has mean 1.
    v_gold:=v_gold+floor(r_mob.kills*(case when r_mob.boss
      then (r_mob.gold_min+r_mob.gold_max)/2.0
      else (20+3*r_mob.level+0.06*r_mob.level*r_mob.level)*0.7 end));
    for r_drop in select dc.item_id,dc.rate_pct from public.offline_hunt_drop_catalog dc where dc.mob_id=r_mob.mob_id loop
      v_expected:=r_mob.kills*r_drop.rate_pct/100.0;
      v_count:=floor(v_expected)+(case when random()<(v_expected-floor(v_expected)) then 1 else 0 end);
      if v_count>0 then v_rewards:=jsonb_set(v_rewards,array[r_drop.item_id],to_jsonb(coalesce((v_rewards->>r_drop.item_id)::bigint,0)+v_count),true); end if;
    end loop;
  end loop;
  v_state:=jsonb_set(cc.state,'{p,exp}',to_jsonb(coalesce((cc.state#>>'{p,exp}')::bigint,0)+v_exp),true);
  v_state:=jsonb_set(v_state,'{p,gold}',to_jsonb(coalesce((cc.state#>>'{p,gold}')::bigint,0)+v_gold),true);
  for r_item in select key as item_id,(value#>>'{}')::bigint as amount from jsonb_each(v_rewards) loop
    v_state:=jsonb_set(v_state,'{p,inv}',coalesce(v_state#>'{p,inv}','[]'::jsonb)||jsonb_build_array(jsonb_build_object('id',r_item.item_id,'cnt',r_item.amount,'en',0,'uid','offline-'||gen_random_uuid()::text)),true);
  end loop;
  v_rev:=cc.revision+1; v_return:=d.map_id not like '%boss%' and d.map_id not like '%hidden%' and d.map_id not like '%key%';
  update public.character_checkpoints x set revision=v_rev,state=v_state,saved_at=v_now where x.character_id=p_character_id;
  update public.offline_hunt_departures x set status='settled',updated_at=v_now where x.character_id=p_character_id;
  insert into public.offline_hunt_settlements(character_id,user_id,request_id,map_id,offline_seconds,effective_seconds,rewards,resulting_revision,resulting_state,return_allowed)
  values(p_character_id,auth.uid(),p_request_id,d.map_id,v_off,v_eff,jsonb_build_object('exp',v_exp,'gold',v_gold,'items',v_rewards,'kills',v_kills),v_rev,v_state,v_return)
  returning id into v_id;
  return jsonb_build_object('settled',true,'settlementId',v_id,'offlineSeconds',v_off,'effectiveSeconds',v_eff,'rewards',jsonb_build_object('exp',v_exp,'gold',v_gold,'items',v_rewards,'kills',v_kills),'revision',v_rev,'state',v_state,'revived',v_off>3600,'returnBlocked',not v_return);
end $$;

create or replace function public.offline_hunt_ack(
  p_session_token uuid,p_character_id uuid,p_settlement_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  perform public.assert_active_game_session(p_session_token);
  update public.offline_hunt_settlements s set acknowledged_at=coalesce(s.acknowledged_at,now()) where s.id=p_settlement_id and s.character_id=p_character_id and s.user_id=auth.uid();
  return jsonb_build_object('ok',found);
end $$;

create or replace function public.offline_hunt_can_return(
  p_session_token uuid,p_character_id uuid,p_map_id text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_active boolean; v_allowed boolean;
begin
  perform public.assert_active_game_session(p_session_token);
  select ohp.expires_at>now() into v_active from public.offline_hunt_passes ohp where ohp.user_id=auth.uid();
  select s.return_allowed and s.map_id=p_map_id into v_allowed from public.offline_hunt_settlements s where s.character_id=p_character_id and s.user_id=auth.uid() order by s.created_at desc limit 1;
  return jsonb_build_object('allowed',coalesce(v_active,false) and coalesce(v_allowed,false));
end $$;

grant execute on function public.sponsor_pass_status(uuid,uuid),public.sponsor_pass_purchase(uuid,uuid,text,uuid),public.offline_hunt_status(uuid,uuid),public.offline_hunt_purchase_pass(uuid,uuid,uuid),public.offline_hunt_arm(uuid,uuid,text,uuid),public.offline_hunt_record_kill(uuid,uuid,text,text,uuid),public.offline_hunt_disarm(uuid,uuid,text),public.offline_hunt_settle(uuid,uuid,uuid),public.offline_hunt_ack(uuid,uuid,uuid),public.offline_hunt_can_return(uuid,uuid,text) to authenticated;
