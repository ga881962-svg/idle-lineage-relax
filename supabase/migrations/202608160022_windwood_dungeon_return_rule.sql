-- Windwood Dungeon is a castle-only hunting area.
-- This is an additive canonical-rule refresh: it changes no player assets,
-- checkpoints, wallets, passes, departures or settlements.

do $$
declare
  v_previous constant text := '8cc21d3d9f49a5622aaf7ab9e5b5c856a49f13136d29447c9c12fa2f1d0ebaa8';
  v_current constant text := '54cfd3334b7a5dcb66324ed9844b5d0e0808f04e8b73d9adde9d350a924b051b';
begin
  if not exists (
    select 1 from public.offline_hunt_catalog_meta
    where singleton = true and source_sha256 = v_previous
  ) then
    raise exception 'OFFLINE_CATALOG_UNEXPECTED_VERSION';
  end if;

  update public.offline_hunt_map_entry_catalog
  set entry_rule = jsonb_set(entry_rule, '{castleRequirement}', '"windwood"'::jsonb, true)
  where map_id = 'windwood_dungeon';

  update public.offline_hunt_mob_catalog set source_sha256 = v_current where source_sha256 = v_previous;
  update public.offline_hunt_map_catalog set source_sha256 = v_current where source_sha256 = v_previous;
  update public.offline_hunt_map_rule_catalog set source_sha256 = v_current where source_sha256 = v_previous;
  update public.offline_hunt_map_entry_catalog set source_sha256 = v_current where source_sha256 = v_previous;
  update public.offline_hunt_drop_catalog set source_sha256 = v_current where source_sha256 = v_previous;
  update public.offline_hunt_item_effect_catalog set source_sha256 = v_current where source_sha256 = v_previous;
  update public.offline_hunt_skill_catalog set source_sha256 = v_current where source_sha256 = v_previous;
  update public.offline_hunt_rule_catalog set source_sha256 = v_current where singleton = true and source_sha256 = v_previous;
  update public.offline_hunt_catalog_meta
  set source_sha256 = v_current, generated_at = now()
  where singleton = true and source_sha256 = v_previous;
end $$;

-- All normal entry, death return and offline return use this one validator.
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
begin
  if p_context not in ('normal_enter','death_return','offline_return') then
    raise exception 'INVALID_MAP_ENTRY_CONTEXT';
  end if;
  ctx := public.server_action_context(p_session_token, p_character_id, p_expected_revision);
  rev := (ctx->>'revision')::bigint;
  select cc.state into st from public.character_checkpoints cc where cc.character_id = p_character_id for update;
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
  st := jsonb_set(st,'{ms,current}',to_jsonb(p_map_id),true);
  rev := public.server_action_next_revision(rev);
  update public.character_checkpoints as cc set state = st, revision = rev, saved_at = now() where cc.character_id = p_character_id;
  if exists(select 1 from public.offline_hunt_map_catalog mc where mc.map_id = p_map_id)
     and coalesce(rule->>'returnBehavior','validate') = 'validate' then
    insert into public.character_last_adventure_maps(character_id,user_id,map_id,catalog_sha256,checkpoint_revision)
    values(p_character_id,auth.uid(),p_map_id,catalog,rev)
    on conflict(character_id) do update set map_id=excluded.map_id,catalog_sha256=excluded.catalog_sha256,recorded_at=now(),checkpoint_revision=excluded.checkpoint_revision;
  end if;
  return jsonb_build_object('allowed',true,'mapId',p_map_id,'context',p_context,'revision',rev,'state',st,'catalogHash',catalog);
end $$;

create or replace function public.offline_hunt_return_check(p_session_token uuid,p_character_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_catalog as $$
declare
  v_map text;
  rule jsonb;
  pass_exp timestamptz;
  st jsonb;
begin
  perform public.assert_active_game_session(p_session_token);
  select sp.expires_at into pass_exp from public.sponsor_passes sp
  where sp.user_id=auth.uid() and sp.pass_kind='offline' and sp.expires_at>now();
  if pass_exp is null then return jsonb_build_object('allowed',false,'reason','OFFLINE_PASS_REQUIRED'); end if;
  select lam.map_id into v_map from public.character_last_adventure_maps lam
  where lam.character_id=p_character_id and lam.user_id=auth.uid();
  if v_map is null then return jsonb_build_object('allowed',false,'reason','MAP_UNAVAILABLE'); end if;
  select mec.entry_rule into rule from public.offline_hunt_map_entry_catalog mec where mec.map_id=v_map;
  if coalesce(rule->>'returnBehavior','validate')='deny' then
    return jsonb_build_object('allowed',false,'mapId',v_map,'reason',coalesce(rule->>'returnReason','MAP_UNAVAILABLE'));
  end if;
  select cc.state into st from public.character_checkpoints cc where cc.character_id=p_character_id;
  if nullif(rule->>'castleRequirement','') is not null
     and coalesce(st#>>'{p,siegeCastle}','') <> rule->>'castleRequirement' then
    return jsonb_build_object('allowed',false,'mapId',v_map,'reason','CASTLE_REQUIRED');
  end if;
  return jsonb_build_object('allowed',true,'mapId',v_map);
end $$;
