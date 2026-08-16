-- Local-only draft.  Do not apply until the client/API rollout is reviewed.
-- Account-wide warehouse and companion progression are server-owned state.

create table if not exists public.account_warehouses (
  user_id uuid not null references auth.users(id) on delete cascade,
  mode_bucket text not null check (mode_bucket in ('normal','classic')),
  gold bigint not null default 0 check (gold >= 0),
  revision bigint not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, mode_bucket)
);
create table if not exists public.account_warehouse_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  mode_bucket text not null check (mode_bucket in ('normal','classic')),
  item_uid text not null,
  item jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, mode_bucket, item_uid),
  check (coalesce(item->>'id','') <> ''),
  check (coalesce((item->>'cnt')::bigint,1) > 0)
);
create index if not exists account_warehouse_items_owner_idx on public.account_warehouse_items(user_id, mode_bucket);
create table if not exists public.warehouse_transfer_requests (
  request_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  character_id uuid not null references public.player_characters(id) on delete cascade,
  result jsonb not null,
  created_at timestamptz not null default now()
);

-- Companion rows are derived from the authoritative character checkpoint for
-- allies. Pet rows are an account-mode roster and are intentionally separate
-- because the browser roster was previously localStorage-only.
create table if not exists public.character_ally_progression (
  character_id uuid not null references public.player_characters(id) on delete cascade,
  ally_slot text not null,
  level integer not null check (level between 1 and 100),
  exp bigint not null check (exp >= 0),
  active boolean not null default false,
  checkpoint_revision bigint not null,
  state jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key(character_id, ally_slot)
);
create table if not exists public.account_pet_progression (
  user_id uuid not null references auth.users(id) on delete cascade,
  mode_bucket text not null check (mode_bucket in ('normal','classic')),
  pet_uid text not null,
  owner_character_id uuid references public.player_characters(id) on delete set null,
  level integer not null check (level between 1 and 100),
  exp bigint not null check (exp >= 0),
  active boolean not null default false,
  progression_revision bigint not null default 0,
  state jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key(user_id, mode_bucket, pet_uid)
);

create or replace function public.sync_checkpoint_ally_progression()
returns trigger language plpgsql security definer set search_path=public as $$
declare a record;
begin
  -- Allies already live in the character checkpoint, so this is an indexed,
  -- revision-bound projection rather than a second client-maintained truth.
  delete from public.character_ally_progression where character_id=new.character_id;
  for a in select value from jsonb_array_elements(coalesce(new.state#>'{p,allies}','[]'::jsonb)) loop
    if coalesce(a.value->>'_slot','')<>'' then
      insert into public.character_ally_progression(character_id,ally_slot,level,exp,active,checkpoint_revision,state)
      values(new.character_id,a.value->>'_slot',least(100,greatest(1,coalesce((a.value->>'lv')::integer,1))),greatest(0,coalesce((a.value->>'exp')::bigint,0)),not coalesce((a.value->>'_downed')::boolean,false),new.revision,a.value)
      on conflict(character_id,ally_slot) do update set level=excluded.level,exp=excluded.exp,active=excluded.active,checkpoint_revision=excluded.checkpoint_revision,state=excluded.state,updated_at=now();
    end if;
  end loop;
  return new;
end $$;
drop trigger if exists character_checkpoint_ally_progression on public.character_checkpoints;
create trigger character_checkpoint_ally_progression after insert or update of state,revision on public.character_checkpoints for each row execute function public.sync_checkpoint_ally_progression();

revoke all on public.account_warehouses, public.account_warehouse_items, public.warehouse_transfer_requests, public.character_ally_progression, public.account_pet_progression from anon, authenticated;

create or replace function public.warehouse_status(p_session_token uuid, p_character_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_bucket text; v_gold bigint; v_revision bigint; v_items jsonb;
begin
  perform public.assert_active_game_session(p_session_token);
  select case when coalesce((cc.state#>>'{p,classicMode}')::boolean,false) then 'classic' else 'normal' end into v_bucket from public.character_checkpoints cc join public.player_characters pc on pc.id=cc.character_id where cc.character_id=p_character_id and pc.user_id=auth.uid();
  if v_bucket is null then raise exception 'CHARACTER_NOT_FOUND'; end if;
  insert into public.account_warehouses(user_id,mode_bucket) values(auth.uid(),v_bucket) on conflict do nothing;
  select gold,revision into v_gold,v_revision from public.account_warehouses where user_id=auth.uid() and mode_bucket=v_bucket;
  select coalesce(jsonb_agg(item order by created_at),'[]'::jsonb) into v_items from public.account_warehouse_items where user_id=auth.uid() and mode_bucket=v_bucket;
  return jsonb_build_object('modeBucket',v_bucket,'gold',v_gold,'revision',v_revision,'items',v_items);
end $$;

create or replace function public.warehouse_transfer(p_session_token uuid,p_character_id uuid,p_request_id uuid,p_expected_revision bigint,p_direction text,p_asset text,p_item_uid text default null,p_quantity bigint default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare cc public.character_checkpoints%rowtype; v_bucket text; v_state jsonb; v_inv jsonb; v_item jsonb; v_wh_item public.account_warehouse_items%rowtype; v_qty bigint; v_count bigint; v_uid text; v_result jsonb; v_gold bigint; v_wh_gold bigint; v_next bigint; v_no_store jsonb;
begin
  perform public.assert_active_game_session(p_session_token);
  if p_direction not in ('deposit','withdraw') or p_asset not in ('gold','item') then raise exception 'INVALID_WAREHOUSE_TRANSFER'; end if;
  select result into v_result from public.warehouse_transfer_requests where request_id=p_request_id and user_id=auth.uid();
  if v_result is not null then return v_result; end if;
  if not exists(select 1 from public.player_characters pc where pc.id=p_character_id and pc.user_id=auth.uid()) then raise exception 'CHARACTER_NOT_FOUND'; end if;
  select * into cc from public.character_checkpoints where character_id=p_character_id for update;
  if cc.state is null then raise exception 'CHECKPOINT_NOT_FOUND'; end if;
  if cc.revision<>p_expected_revision then raise exception 'CHECKPOINT_CONFLICT:%',cc.revision; end if;
  v_bucket:=case when coalesce((cc.state#>>'{p,classicMode}')::boolean,false) then 'classic' else 'normal' end;
  insert into public.account_warehouses(user_id,mode_bucket) values(auth.uid(),v_bucket) on conflict do nothing;
  select gold into v_wh_gold from public.account_warehouses where user_id=auth.uid() and mode_bucket=v_bucket for update;
  -- A duplicate request can arrive while the first request is waiting on this
  -- account lock. Re-read after the lock so it returns the first result.
  select result into v_result from public.warehouse_transfer_requests where request_id=p_request_id and user_id=auth.uid();
  if v_result is not null then return v_result; end if;
  v_state:=cc.state; v_inv:=coalesce(v_state#>'{p,inv}','[]'::jsonb);
  if p_asset='gold' then
    v_qty:=greatest(0,coalesce(p_quantity,0)); if v_qty<1 then raise exception 'INVALID_AMOUNT'; end if;
    v_gold:=greatest(0,coalesce((v_state#>>'{p,gold}')::bigint,0));
    if p_direction='deposit' then if v_gold<v_qty then raise exception 'INSUFFICIENT_GOLD'; end if; v_gold:=v_gold-v_qty; v_wh_gold:=v_wh_gold+v_qty;
    else if v_wh_gold<v_qty then raise exception 'INSUFFICIENT_WAREHOUSE_GOLD'; end if; v_gold:=v_gold+v_qty; v_wh_gold:=v_wh_gold-v_qty; end if;
    v_state:=jsonb_set(v_state,'{p,gold}',to_jsonb(v_gold),true);
  elsif p_direction='deposit' then
    select value into v_item from jsonb_array_elements(v_inv) where value->>'uid'=p_item_uid limit 1;
    if v_item is null or coalesce((v_item->>'lock')::boolean,false) then raise exception 'ITEM_NOT_TRANSFERABLE'; end if;
    select rules#>'{warehouse,noStoreItemIds}' into v_no_store from public.offline_hunt_rule_catalog where singleton=true;
    if coalesce(v_no_store,'[]'::jsonb) ? (v_item->>'id') then raise exception 'WAREHOUSE_ITEM_FORBIDDEN'; end if;
    v_count:=greatest(1,coalesce((v_item->>'cnt')::bigint,1)); v_qty:=least(v_count,greatest(0,coalesce(p_quantity,v_count))); if v_qty<1 then raise exception 'INVALID_AMOUNT'; end if;
    if v_qty=v_count then v_inv:=(select coalesce(jsonb_agg(value),'[]'::jsonb) from jsonb_array_elements(v_inv) where value->>'uid'<>p_item_uid); v_uid:=p_item_uid;
    else v_inv:=(select coalesce(jsonb_agg(case when value->>'uid'=p_item_uid then jsonb_set(value,'{cnt}',to_jsonb(v_count-v_qty)) else value end),'[]'::jsonb) from jsonb_array_elements(v_inv)); v_uid:='wh-'||gen_random_uuid()::text; end if;
    v_item:=jsonb_set(jsonb_set(v_item,'{cnt}',to_jsonb(v_qty),true),'{uid}',to_jsonb(v_uid),true);
    if not exists(select 1 from public.account_warehouse_items where user_id=auth.uid() and mode_bucket=v_bucket and item_uid=v_uid)
       and (select count(*) from public.account_warehouse_items where user_id=auth.uid() and mode_bucket=v_bucket)>=5000 then raise exception 'WAREHOUSE_FULL'; end if;
    insert into public.account_warehouse_items(user_id,mode_bucket,item_uid,item) values(auth.uid(),v_bucket,v_uid,v_item);
    v_state:=jsonb_set(v_state,'{p,inv}',v_inv,true);
  else
    select * into v_wh_item from public.account_warehouse_items where user_id=auth.uid() and mode_bucket=v_bucket and item_uid=p_item_uid for update;
    if not found then raise exception 'WAREHOUSE_ITEM_NOT_FOUND'; end if;
    v_item:=v_wh_item.item; v_count:=greatest(1,coalesce((v_item->>'cnt')::bigint,1)); v_qty:=least(v_count,greatest(0,coalesce(p_quantity,v_count))); if v_qty<1 then raise exception 'INVALID_AMOUNT'; end if;
    if exists(select 1 from jsonb_array_elements(v_inv) value where value->>'uid'=p_item_uid) then raise exception 'DUPLICATE_ITEM_UID'; end if;
    if v_qty=v_count then delete from public.account_warehouse_items where id=v_wh_item.id;
    else update public.account_warehouse_items set item=jsonb_set(item,'{cnt}',to_jsonb(v_count-v_qty)),updated_at=now() where id=v_wh_item.id; v_item:=jsonb_set(v_item,'{uid}',to_jsonb('wh-'||gen_random_uuid()::text)); end if;
    v_item:=jsonb_set(v_item,'{cnt}',to_jsonb(v_qty),true); v_inv:=v_inv||jsonb_build_array(v_item); v_state:=jsonb_set(v_state,'{p,inv}',v_inv,true);
  end if;
  v_next:=cc.revision+1;
  update public.account_warehouses set gold=v_wh_gold,revision=revision+1,updated_at=now() where user_id=auth.uid() and mode_bucket=v_bucket;
  update public.character_checkpoints set state=v_state,revision=v_next,saved_at=now() where character_id=p_character_id;
  v_result:=jsonb_build_object('revision',v_next,'state',v_state,'warehouse',public.warehouse_status(p_session_token,p_character_id));
  insert into public.warehouse_transfer_requests(request_id,user_id,character_id,result) values(p_request_id,auth.uid(),p_character_id,v_result);
  return v_result;
end $$;

-- Replace the snapshot helper only after warehouse tables exist.  Counts are
-- aggregated server-side; no localStorage warehouse value is accepted.
create or replace function public.offline_hunt_warehouse_counts(p_user_id uuid,p_mode_bucket text)
returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_object_agg(item_id,jsonb_build_object('total',total,'unlocked',unlocked,'locked',total-unlocked)),'{}'::jsonb)
  from (select item->>'id' item_id,sum(greatest(1,coalesce((item->>'cnt')::integer,1))) total,sum(case when coalesce((item->>'lock')::boolean,false) then 0 else greatest(1,coalesce((item->>'cnt')::integer,1)) end) unlocked from public.account_warehouse_items where user_id=p_user_id and mode_bucket=p_mode_bucket group by item->>'id') x
$$;

-- Generic, all-or-nothing warehouse debit. Callers must perform any NPC/quest
-- reward in this same database transaction (a client-side reward is forbidden).
create or replace function public.warehouse_consume(p_session_token uuid,p_character_id uuid,p_request_id uuid,p_expected_revision bigint,p_requirements jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare cc public.character_checkpoints%rowtype; r jsonb; v_bucket text; v_gold bigint; v_qty bigint; wi public.account_warehouse_items%rowtype; v_result jsonb; v_next bigint;
begin
  perform public.assert_active_game_session(p_session_token);
  if jsonb_typeof(p_requirements)<>'array' then raise exception 'INVALID_REQUIREMENTS'; end if;
  select result into v_result from public.warehouse_transfer_requests where request_id=p_request_id and user_id=auth.uid(); if v_result is not null then return v_result; end if;
  if not exists(select 1 from public.player_characters where id=p_character_id and user_id=auth.uid()) then raise exception 'CHARACTER_NOT_FOUND'; end if;
  select * into cc from public.character_checkpoints where character_id=p_character_id for update;
  if cc.revision<>p_expected_revision then raise exception 'CHECKPOINT_CONFLICT:%',cc.revision; end if;
  v_bucket:=case when coalesce((cc.state#>>'{p,classicMode}')::boolean,false) then 'classic' else 'normal' end;
  insert into public.account_warehouses(user_id,mode_bucket) values(auth.uid(),v_bucket) on conflict do nothing;
  select gold into v_gold from public.account_warehouses where user_id=auth.uid() and mode_bucket=v_bucket for update;
  -- Validate every requirement before changing any row.
  for r in select value from jsonb_array_elements(p_requirements) loop
    v_qty:=greatest(0,coalesce((r->>'quantity')::bigint,0)); if v_qty<1 then raise exception 'INVALID_AMOUNT'; end if;
    if r->>'asset'='gold' then if v_gold<v_qty then raise exception 'INSUFFICIENT_WAREHOUSE_GOLD'; end if;
    elsif r->>'asset'='item' then
      if coalesce(r->>'uid','')='' then raise exception 'WAREHOUSE_ITEM_UID_REQUIRED'; end if;
      select * into wi from public.account_warehouse_items where user_id=auth.uid() and mode_bucket=v_bucket and item_uid=r->>'uid' for update;
      if not found or wi.item->>'id'<>r->>'itemId' or coalesce((wi.item->>'lock')::boolean,false) or greatest(1,coalesce((wi.item->>'cnt')::bigint,1))<v_qty then raise exception 'INSUFFICIENT_WAREHOUSE_ITEM'; end if;
    else raise exception 'INVALID_REQUIREMENT_ASSET'; end if;
  end loop;
  for r in select value from jsonb_array_elements(p_requirements) loop
    v_qty:=(r->>'quantity')::bigint;
    if r->>'asset'='gold' then v_gold:=v_gold-v_qty;
    else select * into wi from public.account_warehouse_items where user_id=auth.uid() and mode_bucket=v_bucket and item_uid=r->>'uid' for update;
      if greatest(1,coalesce((wi.item->>'cnt')::bigint,1))=v_qty then delete from public.account_warehouse_items where id=wi.id;
      else update public.account_warehouse_items set item=jsonb_set(item,'{cnt}',to_jsonb((item->>'cnt')::bigint-v_qty)),updated_at=now() where id=wi.id; end if;
    end if;
  end loop;
  v_next:=cc.revision+1; update public.account_warehouses set gold=v_gold,revision=revision+1,updated_at=now() where user_id=auth.uid() and mode_bucket=v_bucket;
  update public.character_checkpoints set revision=v_next,saved_at=now() where character_id=p_character_id;
  v_result:=jsonb_build_object('revision',v_next,'warehouse',public.warehouse_status(p_session_token,p_character_id));
  insert into public.warehouse_transfer_requests(request_id,user_id,character_id,result) values(p_request_id,auth.uid(),p_character_id,v_result);
  return v_result;
end $$;

grant execute on function public.warehouse_status(uuid,uuid),public.warehouse_transfer(uuid,uuid,uuid,bigint,text,text,text,bigint),public.warehouse_consume(uuid,uuid,uuid,bigint,jsonb),public.offline_hunt_warehouse_counts(uuid,text) to authenticated;
