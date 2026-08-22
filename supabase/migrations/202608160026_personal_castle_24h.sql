-- Personal castle ownership is server-timed.  A claim lasts exactly 24 hours;
-- guards are intentionally not stored here: they become inactive whenever the
-- owning claim is no longer active.

create table if not exists public.character_castle_claims (
  character_id uuid primary key references public.player_characters(id) on delete cascade,
  city text not null check (city in ('kent','windwood','heine')),
  claimed_at timestamptz not null default now(),
  expires_at timestamptz not null,
  updated_at timestamptz not null default now(),
  check (expires_at = claimed_at + interval '24 hours')
);
create index if not exists character_castle_claims_active_idx
  on public.character_castle_claims(expires_at);

alter table public.character_castle_claims enable row level security;
revoke all on public.character_castle_claims from public, anon, authenticated;

create or replace function public.personal_castle_status(
  p_session_token uuid,
  p_character_id uuid
) returns jsonb
language plpgsql security definer set search_path=public,pg_catalog as $$
declare v_claim public.character_castle_claims%rowtype;
begin
  perform public.server_action_context(p_session_token,p_character_id,null);
  select * into v_claim from public.character_castle_claims
    where character_id=p_character_id and expires_at>now();
  if not found then
    return jsonb_build_object('active',false,'city',null,'expiresAt',null);
  end if;
  return jsonb_build_object('active',true,'city',v_claim.city,'claimedAt',v_claim.claimed_at,'expiresAt',v_claim.expires_at);
end $$;

-- The current siege engine is client-run; this function does not alter battle
-- resolution.  It is the sole place that establishes the server timestamp and
-- writes the resulting personal ownership state after that engine reports a win.
create or replace function public.personal_castle_claim(
  p_session_token uuid,
  p_character_id uuid,
  p_city text,
  p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=public,pg_catalog as $$
declare v_ctx jsonb; v_state jsonb; v_revision bigint; v_result jsonb; v_begin jsonb;
declare v_hash text;
begin
  if p_city not in ('kent','windwood','heine') then raise exception 'INVALID_CASTLE_CITY'; end if;
  if p_request_id is null then raise exception 'INVALID_REQUEST_ID'; end if;
  v_ctx:=public.server_action_context(p_session_token,p_character_id,null);
  v_hash:=encode(digest(jsonb_build_object('characterId',p_character_id,'city',p_city)::text,'sha256'),'hex');
  v_begin:=public.server_action_begin(p_session_token,'castle.claim',p_request_id,v_hash,v_ctx->>'modeBucket',p_character_id);
  if v_begin->>'state'='completed' then return v_begin->'result'; end if;
  if v_begin->>'state'='failed' then raise exception '%',coalesce(v_begin->>'errorCode','CASTLE_CLAIM_FAILED'); end if;

  select state,revision into v_state,v_revision from public.character_checkpoints where character_id=p_character_id for update;
  if v_state is null then raise exception 'CHECKPOINT_NOT_FOUND'; end if;
  insert into public.character_castle_claims(character_id,city,claimed_at,expires_at,updated_at)
    values(p_character_id,p_city,now(),now()+interval '24 hours',now())
    on conflict(character_id) do update set city=excluded.city,claimed_at=excluded.claimed_at,expires_at=excluded.expires_at,updated_at=excluded.updated_at;
  v_state:=jsonb_set(v_state,'{p,siegeCastle}',to_jsonb(p_city),true);
  v_state:=jsonb_set(v_state,'{p,siegeCastleExpiresAt}',to_jsonb(extract(epoch from now()+interval '24 hours')*1000),true);
  v_revision:=public.server_action_next_revision(v_revision);
  update public.character_checkpoints set state=v_state,revision=v_revision,saved_at=now() where character_id=p_character_id;
  v_result:=jsonb_build_object('active',true,'city',p_city,'claimedAt',now(),'expiresAt',now()+interval '24 hours','revision',v_revision,'state',v_state,'replayed',false);
  perform public.server_action_complete(p_session_token,'castle.claim',p_request_id,v_result);
  return v_result;
exception when others then
  if v_ctx is not null and p_request_id is not null then
    begin perform public.server_action_fail(p_session_token,'castle.claim',p_request_id,split_part(sqlerrm,':',1),jsonb_build_object('message',sqlerrm)); exception when others then null; end;
  end if;
  raise;
end $$;

revoke all on function public.personal_castle_status(uuid,uuid),public.personal_castle_claim(uuid,uuid,text,uuid) from public,anon;
grant execute on function public.personal_castle_status(uuid,uuid),public.personal_castle_claim(uuid,uuid,text,uuid) to authenticated;

-- Map entry must use the lease table, not an old client checkpoint field.
create or replace function public.map_entry_validate_and_apply(
  p_session_token uuid,p_character_id uuid,p_map_id text,p_context text,p_request_id uuid,p_expected_revision bigint
) returns jsonb language plpgsql security definer set search_path=public,pg_catalog as $$
declare ctx jsonb; st jsonb; rev bigint; rule jsonb; catalog text; item_id text; qty bigint; pass_exp timestamptz; current_map text; castle_city text;
begin
  if p_context not in ('normal_enter','death_return','offline_return') then raise exception 'INVALID_MAP_ENTRY_CONTEXT'; end if;
  if p_context in ('death_return','offline_return') then perform public.server_action_require_flag('offline_settlement_v2'); end if;
  ctx:=public.server_action_context(p_session_token,p_character_id,p_expected_revision);
  rev:=(ctx->>'revision')::bigint;
  select cc.state into st from public.character_checkpoints cc where cc.character_id=p_character_id for update;
  current_map:=coalesce(st#>>'{ms,current}','');
  if p_context='death_return' and current_map in ('pvp_arena','duel_arena','kent_outer','kent_inner','ww_outer','ww_inner','heine_outer','heine_inner') then raise exception 'PVP_RETURN_DISABLED'; end if;
  select mec.entry_rule,mec.source_sha256 into rule,catalog from public.offline_hunt_map_entry_catalog mec where mec.map_id=p_map_id;
  if rule is null then raise exception 'MAP_UNAVAILABLE'; end if;
  if p_context in ('death_return','offline_return') then
    select sp.expires_at into pass_exp from public.sponsor_passes sp where sp.user_id=auth.uid() and sp.pass_kind='offline' and sp.expires_at>now();
    if pass_exp is null then raise exception 'OFFLINE_PASS_REQUIRED'; end if;
    if coalesce(rule->>'returnBehavior','validate')='deny' then raise exception '%',coalesce(rule->>'returnReason','MAP_UNAVAILABLE'); end if;
  end if;
  select c.city into castle_city from public.character_castle_claims c where c.character_id=p_character_id and c.expires_at>now();
  if nullif(rule->>'castleRequirement','') is not null and coalesce(castle_city,'')<>rule->>'castleRequirement' then raise exception 'CASTLE_REQUIRED'; end if;
  if coalesce((st#>>'{p,lv}')::int,1)<coalesce((rule->>'levelRequirement')::int,1) then raise exception 'LEVEL_REQUIRED'; end if;
  if rule->>'questRequirement'='demonTemple' and not coalesce((st#>>'{p,demonTempleOpen}')::boolean,false) then raise exception 'QUEST_REQUIRED'; end if;
  if rule->>'affinityRequirement' is not null and coalesce((st#>>'{p,flameAffinity}')::int,0)<(rule->>'affinityRequirement')::int then raise exception 'PASS_REQUIRED'; end if;
  item_id:=nullif(rule->>'requiredItem',''); if item_id is not null and public.offline_hunt_inventory_count(st,item_id)<1 then raise exception 'MISSING_KEY'; end if;
  if rule->>'prideTier' is not null then
    select p.value->>'itemId' into item_id from jsonb_array_elements(coalesce(rule->'prideItems','[]'::jsonb)) p where p.value->>'kind'='scroll' and public.offline_hunt_inventory_count(st,p.value->>'itemId')>0 limit 1;
    if item_id is null and not exists(select 1 from jsonb_array_elements(coalesce(rule->'prideItems','[]'::jsonb)) p where p.value->>'kind' in ('pass','dom') and public.offline_hunt_inventory_count(st,p.value->>'itemId')>0) then raise exception 'MISSING_SCROLL'; end if;
    if item_id is not null then st:=public.offline_hunt_inventory_consume(st,item_id,1); end if;
  end if;
  item_id:=nullif(rule->>'consumableItem',''); qty:=coalesce((rule->>'consumableQuantity')::bigint,0); if item_id is not null and qty>0 then st:=public.offline_hunt_inventory_consume(st,item_id,qty); end if;
  if p_context='death_return' then
    st:=jsonb_set(st,'{p,dead}','false'::jsonb,true);
    st:=jsonb_set(st,'{p,hp}',to_jsonb(greatest(1,least(coalesce((st#>>'{p,mhp}')::int,1),200))),true);
    st:=jsonb_set(st,'{p,statuses}',jsonb_build_object('stun',0,'freeze',0,'stone',0,'poison',0,'poisonDmg',0,'poisonTick',0,'burn',0,'burnDmg',0,'burnTick',0,'scald',0,'scaldDmg',0,'scaldTick',0,'bleed',0,'bleedDmg',0,'bleedTick',0,'sleep',0,'silence',0,'paralyze',0,'magicseal',0,'armorBreak',0,'slowAtk',0,'cleave',0,'evilAura',0),true);
  end if;
  st:=jsonb_set(st,'{ms,current}',to_jsonb(p_map_id),true); rev:=public.server_action_next_revision(rev);
  update public.character_checkpoints as cc set state=st,revision=rev,saved_at=now() where cc.character_id=p_character_id;
  if exists(select 1 from public.offline_hunt_map_catalog mc where mc.map_id=p_map_id) and coalesce(rule->>'returnBehavior','validate')='validate' then
    insert into public.character_last_adventure_maps(character_id,user_id,map_id,catalog_sha256,checkpoint_revision) values(p_character_id,auth.uid(),p_map_id,catalog,rev)
    on conflict(character_id) do update set map_id=excluded.map_id,catalog_sha256=excluded.catalog_sha256,recorded_at=now(),checkpoint_revision=excluded.checkpoint_revision;
  end if;
  return jsonb_build_object('allowed',true,'mapId',p_map_id,'context',p_context,'revision',rev,'state',st,'catalogHash',catalog);
end $$;
