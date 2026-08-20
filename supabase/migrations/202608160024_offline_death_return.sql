-- Canonical online death return hotfix.
-- Reuses the existing map-entry RPC and rules; it only makes a successful
-- death_return persist the same revival state the client will render.
-- No player row is touched until a player invokes death_return.

create or replace function public.map_entry_validate_and_apply(
  p_session_token uuid,
  p_character_id uuid,
  p_map_id text,
  p_context text,
  p_request_id uuid,
  p_expected_revision bigint
)
returns jsonb language plpgsql security definer set search_path=public,pg_catalog as $$
declare
  ctx jsonb;
  st jsonb;
  rev bigint;
  rule jsonb;
  catalog text;
  item_id text;
  qty bigint;
  pass_exp timestamptz;
  current_map text;
begin
  if p_context not in ('normal_enter','death_return','offline_return') then
    raise exception 'INVALID_MAP_ENTRY_CONTEXT';
  end if;
  if p_context in ('death_return','offline_return') then
    perform public.server_action_require_flag('offline_settlement_v2');
  end if;
  ctx := public.server_action_context(p_session_token, p_character_id, p_expected_revision);
  rev := (ctx->>'revision')::bigint;
  select cc.state into st from public.character_checkpoints cc where cc.character_id = p_character_id for update;
  current_map := coalesce(st#>>'{ms,current}','');
  -- A death in PvP / siege must never use a previously saved hunting map to
  -- escape.  These maps are intentionally denied before any return mutation.
  if p_context = 'death_return' and current_map in ('pvp_arena','duel_arena','kent_outer','kent_inner','ww_outer','ww_inner','heine_outer','heine_inner') then
    raise exception 'PVP_RETURN_DISABLED';
  end if;
  select mec.entry_rule, mec.source_sha256 into rule, catalog
    from public.offline_hunt_map_entry_catalog mec where mec.map_id = p_map_id;
  if rule is null then raise exception 'MAP_UNAVAILABLE'; end if;

  if p_context in ('death_return','offline_return') then
    select sp.expires_at into pass_exp from public.sponsor_passes sp
      where sp.user_id = auth.uid() and sp.pass_kind = 'offline' and sp.expires_at > now();
    if pass_exp is null then raise exception 'OFFLINE_PASS_REQUIRED'; end if;
    if coalesce(rule->>'returnBehavior','validate') = 'deny' then
      raise exception '%', coalesce(rule->>'returnReason','MAP_UNAVAILABLE');
    end if;
  end if;

  if nullif(rule->>'castleRequirement','') is not null
     and coalesce(st#>>'{p,siegeCastle}','') <> rule->>'castleRequirement' then
    raise exception 'CASTLE_REQUIRED';
  end if;
  if coalesce((st#>>'{p,lv}')::int,1) < coalesce((rule->>'levelRequirement')::int,1) then raise exception 'LEVEL_REQUIRED'; end if;
  if rule->>'questRequirement' = 'demonTemple' and not coalesce((st#>>'{p,demonTempleOpen}')::boolean,false) then raise exception 'QUEST_REQUIRED'; end if;
  if (rule->>'affinityRequirement') is not null and coalesce((st#>>'{p,flameAffinity}')::int,0) < (rule->>'affinityRequirement')::int then raise exception 'PASS_REQUIRED'; end if;
  item_id := nullif(rule->>'requiredItem','');
  if item_id is not null and public.offline_hunt_inventory_count(st,item_id) < 1 then raise exception 'MISSING_KEY'; end if;
  if (rule->>'prideTier') is not null then
    select p.value->>'itemId' into item_id
      from jsonb_array_elements(coalesce(rule->'prideItems','[]'::jsonb)) p
      where p.value->>'kind' = 'scroll' and public.offline_hunt_inventory_count(st,p.value->>'itemId') > 0 limit 1;
    if item_id is null and not exists (
      select 1 from jsonb_array_elements(coalesce(rule->'prideItems','[]'::jsonb)) p
       where p.value->>'kind' in ('pass','dom') and public.offline_hunt_inventory_count(st,p.value->>'itemId') > 0
    ) then raise exception 'MISSING_SCROLL'; end if;
    if item_id is not null then st := public.offline_hunt_inventory_consume(st,item_id,1); end if;
  end if;
  item_id := nullif(rule->>'consumableItem','');
  qty := coalesce((rule->>'consumableQuantity')::bigint,0);
  if item_id is not null and qty > 0 then st := public.offline_hunt_inventory_consume(st,item_id,qty); end if;

  if p_context = 'death_return' then
    -- Match the existing in-place revival baseline: alive, all statuses
    -- cleared and a bounded HP recovery.  No client-supplied health is used.
    st := jsonb_set(st,'{p,dead}','false'::jsonb,true);
    st := jsonb_set(st,'{p,hp}',to_jsonb(greatest(1, least(coalesce((st#>>'{p,mhp}')::int,1), 200))),true);
    st := jsonb_set(st,'{p,statuses}',jsonb_build_object(
      'stun',0,'freeze',0,'stone',0,'poison',0,'poisonDmg',0,'poisonTick',0,
      'burn',0,'burnDmg',0,'burnTick',0,'scald',0,'scaldDmg',0,'scaldTick',0,
      'bleed',0,'bleedDmg',0,'bleedTick',0,'sleep',0,'silence',0,'paralyze',0,
      'magicseal',0,'armorBreak',0,'slowAtk',0,'cleave',0,'evilAura',0
    ),true);
  end if;
  st := jsonb_set(st,'{ms,current}',to_jsonb(p_map_id),true);
  rev := public.server_action_next_revision(rev);
  update public.character_checkpoints as cc
     set state = st, revision = rev, saved_at = now()
   where cc.character_id = p_character_id;
  if exists(select 1 from public.offline_hunt_map_catalog mc where mc.map_id = p_map_id)
     and coalesce(rule->>'returnBehavior','validate') = 'validate' then
    insert into public.character_last_adventure_maps(character_id,user_id,map_id,catalog_sha256,checkpoint_revision)
    values(p_character_id,auth.uid(),p_map_id,catalog,rev)
    on conflict(character_id) do update
       set map_id=excluded.map_id,catalog_sha256=excluded.catalog_sha256,
           recorded_at=now(),checkpoint_revision=excluded.checkpoint_revision;
  end if;
  return jsonb_build_object('allowed',true,'mapId',p_map_id,'context',p_context,'revision',rev,'state',st,'catalogHash',catalog);
end $$;
