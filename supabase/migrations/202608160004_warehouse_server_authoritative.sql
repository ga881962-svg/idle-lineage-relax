-- Phase 1: account/mode shared warehouse.  This migration deliberately does
-- not implement warehouse consumption; crafting, quest and NPC actions remain
-- on their existing paths until their own atomic server-action phase.

-- Self-contained on top of Phase 0.  Do not require the earlier broad shared
-- state draft: that draft also carries pet/offline work outside this phase.
create table if not exists public.account_warehouses (
  user_id uuid not null references auth.users(id) on delete cascade,
  mode_bucket text not null check (mode_bucket in ('normal','classic')),
  gold bigint not null default 0 check (gold >= 0),
  revision bigint not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id,mode_bucket)
);
create table if not exists public.account_warehouse_items (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  mode_bucket text not null check (mode_bucket in ('normal','classic')),
  item_uid text not null,
  item jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id,mode_bucket,item_uid),
  check (coalesce(item->>'id','') <> ''),
  check (coalesce((item->>'cnt')::bigint,1) > 0)
);
create index if not exists account_warehouse_items_owner_idx on public.account_warehouse_items(user_id,mode_bucket);
alter table public.account_warehouses enable row level security;
alter table public.account_warehouse_items enable row level security;
revoke all on public.account_warehouses,public.account_warehouse_items from anon,authenticated;

alter table public.account_warehouses
  add column if not exists migration_kind text,
  add column if not exists migrated_at timestamptz;
alter table public.account_warehouse_items
  add column if not exists locked boolean not null default false,
  add column if not exists metadata jsonb not null default '{}'::jsonb;

-- The browser item object is preserved verbatim in `item`.  These generated
-- columns make ownership/quantity checks indexable without reducing a UID
-- weapon or armour to an item id + count.
alter table public.account_warehouse_items
  add column if not exists item_id text generated always as (item->>'id') stored,
  add column if not exists quantity bigint generated always as (greatest(1,coalesce((item->>'cnt')::bigint,1))) stored;
create index if not exists account_warehouse_items_owner_item_idx
  on public.account_warehouse_items(user_id,mode_bucket,item_id);

create or replace function public.warehouse__state(p_user_id uuid, p_mode_bucket text)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'modeBucket', p_mode_bucket,
    'gold', coalesce((select gold from public.account_warehouses where user_id=p_user_id and mode_bucket=p_mode_bucket),0),
    'revision', coalesce((select revision from public.account_warehouses where user_id=p_user_id and mode_bucket=p_mode_bucket),0),
    'items', coalesce((select jsonb_agg(item order by created_at,item_uid) from public.account_warehouse_items where user_id=p_user_id and mode_bucket=p_mode_bucket),'[]'::jsonb)
  )
$$;

create or replace function public.warehouse__mode(p_character_id uuid)
returns text language sql stable security definer set search_path=public as $$
  select case when coalesce((state#>>'{p,classicMode}')::boolean,false) then 'classic' else 'normal' end
  from public.character_checkpoints where character_id=p_character_id
$$;

create or replace function public.warehouse__migration_completed(p_user_id uuid,p_mode_bucket text)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.server_migration_markers
    where user_id=p_user_id and mode_bucket=p_mode_bucket
      and migration_kind='warehouse.localstorage.v1' and status='completed')
$$;

create or replace function public.warehouse_status(p_session_token uuid,p_character_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_context jsonb; v_mode text; v_done boolean;
begin
  perform public.server_action_require_flag('warehouse_server_authoritative');
  v_context:=public.server_action_context(p_session_token,p_character_id,null);
  v_mode:=v_context->>'modeBucket';
  v_done:=public.warehouse__migration_completed(auth.uid(),v_mode);
  if not v_done then
    return jsonb_build_object('authoritative',false,'migrationRequired',true,'modeBucket',v_mode);
  end if;
  return public.warehouse__state(auth.uid(),v_mode) || jsonb_build_object('authoritative',true,'migrationRequired',false);
end $$;

-- A localStorage source is accepted at most once per account/mode.  The server
-- computes the source fingerprint from jsonb, validates all rows first and
-- stores whole item documents including UID/enchant/blessing/element/options.
create or replace function public.warehouse_migrate(
  p_session_token uuid,p_character_id uuid,p_request_id uuid,p_legacy jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_context jsonb; v_mode text; v_source_hash text; v_begin jsonb; v_action jsonb;
  v_gold bigint; v_items jsonb; v_item jsonb; v_uid text; v_count integer; v_result jsonb;
begin
  perform public.server_action_require_flag('warehouse_server_authoritative');
  if p_request_id is null or jsonb_typeof(p_legacy) <> 'object' then raise exception 'INVALID_WAREHOUSE_MIGRATION'; end if;
  v_context:=public.server_action_context(p_session_token,p_character_id,null);
  v_mode:=v_context->>'modeBucket';
  v_source_hash:=pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_legacy::text,'UTF8'::name),'sha256'::text),'hex'::text);

  -- This locks the marker before the warehouse and makes a second device
  -- replay the completed metadata rather than importing its stale bucket.
  v_begin:=public.server_migration_begin(p_session_token,v_mode,'warehouse.localstorage.v1',p_request_id,v_source_hash);
  if v_begin->>'state'='completed' then return (v_begin->'metadata') || jsonb_build_object('replayed',true); end if;
  v_action:=public.server_action_begin(p_session_token,'warehouse.migrate',p_request_id,v_source_hash,v_mode,p_character_id);
  if v_action->>'state'='completed' then return v_action->'result'; end if;
  if v_action->>'state'='failed' then raise exception '%',coalesce(v_action->>'errorCode','WAREHOUSE_MIGRATION_FAILED'); end if;

  v_gold:=coalesce((p_legacy->>'gold')::bigint,0);
  v_items:=coalesce(p_legacy->'items','[]'::jsonb);
  if v_gold < 0 or jsonb_typeof(v_items)<>'array' or jsonb_array_length(v_items)>5000 then raise exception 'INVALID_WAREHOUSE_MIGRATION'; end if;
  if exists(select 1 from jsonb_array_elements(v_items) x(value)
    where coalesce(x.value->>'id','')='' or coalesce(x.value->>'uid','')='' or coalesce((x.value->>'cnt')::bigint,1)<1)
     or (select count(*) from (select value->>'uid' uid from jsonb_array_elements(v_items) group by value->>'uid' having count(*)>1) d)>0 then
    raise exception 'INVALID_WAREHOUSE_ITEMS';
  end if;

  insert into public.account_warehouses(user_id,mode_bucket,gold,revision,migration_kind,migrated_at)
  values(auth.uid(),v_mode,v_gold,0,'warehouse.localstorage.v1',now())
  on conflict(user_id,mode_bucket) do nothing;
  if exists(select 1 from public.account_warehouse_items where user_id=auth.uid() and mode_bucket=v_mode) then
    raise exception 'WAREHOUSE_ALREADY_POPULATED';
  end if;
  for v_item in select value from jsonb_array_elements(v_items) loop
    v_uid:=v_item->>'uid';
    insert into public.account_warehouse_items(user_id,mode_bucket,item_uid,item,locked,metadata)
      values(auth.uid(),v_mode,v_uid,v_item,coalesce((v_item->>'lock')::boolean,false),v_item - 'uid' - 'id' - 'cnt');
  end loop;
  v_result:=public.warehouse__state(auth.uid(),v_mode) || jsonb_build_object('authoritative',true,'migrationRequired',false,'migrated',true);
  perform public.server_migration_complete(p_session_token,v_mode,'warehouse.localstorage.v1',p_request_id,v_result);
  perform public.server_action_complete(p_session_token,'warehouse.migrate',p_request_id,v_result);
  return v_result;
end $$;

create or replace function public.warehouse_transfer(
  p_session_token uuid,p_character_id uuid,p_request_id uuid,p_expected_revision bigint,
  p_direction text,p_asset text,p_item_uid text default null,p_quantity bigint default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_hash text; v_known public.server_action_requests%rowtype; v_context jsonb; v_mode text;
  v_checkpoint public.character_checkpoints%rowtype; v_warehouse public.account_warehouses%rowtype;
  v_state jsonb; v_inv jsonb; v_item jsonb; v_wh_item public.account_warehouse_items%rowtype;
  v_qty bigint; v_count bigint; v_gold bigint; v_new_uid text; v_result jsonb; v_started jsonb;
begin
  perform public.server_action_require_flag('warehouse_server_authoritative');
  if p_direction not in ('deposit','withdraw') or p_asset not in ('gold','item') or p_request_id is null or p_expected_revision is null then raise exception 'INVALID_WAREHOUSE_TRANSFER'; end if;
  v_hash:=pg_catalog.encode(extensions.digest(pg_catalog.convert_to(jsonb_build_object('characterId',p_character_id,'revision',p_expected_revision,'direction',p_direction,'asset',p_asset,'itemUid',p_item_uid,'quantity',p_quantity)::text,'UTF8'::name),'sha256'::text),'hex'::text);

  -- Fast replay is deliberately before revision validation: a network retry
  -- retains its original result even though the first call advanced revision.
  select * into v_known from public.server_action_requests where user_id=auth.uid() and action_type='warehouse.transfer' and request_id=p_request_id;
  if found then
    if v_known.request_hash<>v_hash then raise exception 'REQUEST_ID_PAYLOAD_MISMATCH'; end if;
    if v_known.status='completed' then return v_known.result; end if;
    if v_known.status='failed' then raise exception '%',coalesce(v_known.error_code,'WAREHOUSE_TRANSFER_FAILED'); end if;
  end if;
  v_context:=public.server_action_context(p_session_token,p_character_id,null);
  v_mode:=v_context->>'modeBucket';
  if not public.warehouse__migration_completed(auth.uid(),v_mode) then raise exception 'WAREHOUSE_MIGRATION_REQUIRED'; end if;
  select * into v_checkpoint from public.character_checkpoints where character_id=p_character_id for update;
  if v_checkpoint.revision<>p_expected_revision then
    -- A concurrent identical request waits on this lock; replay it after the
    -- first transaction commits instead of treating its former revision stale.
    select * into v_known from public.server_action_requests where user_id=auth.uid() and action_type='warehouse.transfer' and request_id=p_request_id;
    if found and v_known.request_hash=v_hash and v_known.status='completed' then return v_known.result; end if;
    raise exception 'CHECKPOINT_CONFLICT:%',v_checkpoint.revision;
  end if;
  select * into v_warehouse from public.account_warehouses where user_id=auth.uid() and mode_bucket=v_mode for update;
  if not found then raise exception 'WAREHOUSE_NOT_MIGRATED'; end if;
  v_started:=public.server_action_begin(p_session_token,'warehouse.transfer',p_request_id,v_hash,v_mode,p_character_id);
  if v_started->>'state'='completed' then return v_started->'result'; end if;
  if v_started->>'state'='failed' then raise exception '%',coalesce(v_started->>'errorCode','WAREHOUSE_TRANSFER_FAILED'); end if;
  v_state:=v_checkpoint.state; v_inv:=coalesce(v_state#>'{p,inv}','[]'::jsonb); v_gold:=coalesce((v_state#>>'{p,gold}')::bigint,0);
  v_qty:=coalesce(p_quantity,0); if v_qty<1 then raise exception 'INVALID_AMOUNT'; end if;
  if p_asset='gold' then
    if p_direction='deposit' then if v_gold<v_qty then raise exception 'INSUFFICIENT_GOLD'; end if; v_gold:=v_gold-v_qty; v_warehouse.gold:=v_warehouse.gold+v_qty;
    else if v_warehouse.gold<v_qty then raise exception 'INSUFFICIENT_WAREHOUSE_GOLD'; end if; v_gold:=v_gold+v_qty; v_warehouse.gold:=v_warehouse.gold-v_qty; end if;
    v_state:=jsonb_set(v_state,'{p,gold}',to_jsonb(v_gold),true);
  elsif p_direction='deposit' then
    select value into v_item from jsonb_array_elements(v_inv) where value->>'uid'=p_item_uid limit 1;
    if v_item is null or coalesce((v_item->>'lock')::boolean,false) then raise exception 'ITEM_NOT_TRANSFERABLE'; end if;
    v_count:=greatest(1,coalesce((v_item->>'cnt')::bigint,1)); if v_qty>v_count then raise exception 'INSUFFICIENT_ITEM_QUANTITY'; end if;
    if v_qty=v_count then
      v_inv:=(select coalesce(jsonb_agg(value),'[]'::jsonb) from jsonb_array_elements(v_inv) where value->>'uid'<>p_item_uid); v_new_uid:=p_item_uid;
    else
      v_new_uid:='wh-'||pg_catalog.gen_random_uuid()::text;
      v_inv:=(select coalesce(jsonb_agg(case when value->>'uid'=p_item_uid then jsonb_set(value,'{cnt}',to_jsonb(v_count-v_qty),true) else value end),'[]'::jsonb) from jsonb_array_elements(v_inv));
    end if;
    v_item:=jsonb_set(jsonb_set(v_item,'{uid}',to_jsonb(v_new_uid),true),'{cnt}',to_jsonb(v_qty),true);
    if (select count(*) from public.account_warehouse_items where user_id=auth.uid() and mode_bucket=v_mode)>=5000 then raise exception 'WAREHOUSE_FULL'; end if;
    insert into public.account_warehouse_items(user_id,mode_bucket,item_uid,item,locked,metadata) values(auth.uid(),v_mode,v_new_uid,v_item,false,v_item-'uid'-'id'-'cnt');
    v_state:=jsonb_set(v_state,'{p,inv}',v_inv,true);
  else
    select * into v_wh_item from public.account_warehouse_items where user_id=auth.uid() and mode_bucket=v_mode and item_uid=p_item_uid for update;
    if not found then raise exception 'WAREHOUSE_ITEM_NOT_FOUND'; end if;
    if v_wh_item.locked then raise exception 'WAREHOUSE_ITEM_LOCKED'; end if;
    v_item:=v_wh_item.item; v_count:=v_wh_item.quantity; if v_qty>v_count then raise exception 'INSUFFICIENT_WAREHOUSE_ITEM'; end if;
    if jsonb_array_length(v_inv)>=5000 then raise exception 'INVENTORY_FULL'; end if;
    if v_qty=v_count then
      if exists(select 1 from jsonb_array_elements(v_inv) where value->>'uid'=p_item_uid) then raise exception 'DUPLICATE_ITEM_UID'; end if;
      delete from public.account_warehouse_items where id=v_wh_item.id;
    else
      v_new_uid:='wh-'||pg_catalog.gen_random_uuid()::text;
      update public.account_warehouse_items set item=jsonb_set(item,'{cnt}',to_jsonb(v_count-v_qty),true),updated_at=now() where id=v_wh_item.id;
      v_item:=jsonb_set(v_item,'{uid}',to_jsonb(v_new_uid),true);
    end if;
    v_item:=jsonb_set(v_item,'{cnt}',to_jsonb(v_qty),true); v_inv:=v_inv||jsonb_build_array(v_item); v_state:=jsonb_set(v_state,'{p,inv}',v_inv,true);
  end if;
  update public.account_warehouses set gold=v_warehouse.gold,revision=public.server_action_next_revision(v_warehouse.revision),updated_at=now() where user_id=auth.uid() and mode_bucket=v_mode;
  update public.character_checkpoints set state=v_state,revision=public.server_action_next_revision(v_checkpoint.revision),saved_at=now() where character_id=p_character_id;
  v_result:=jsonb_build_object('revision',public.server_action_next_revision(v_checkpoint.revision),'state',v_state,'warehouse',public.warehouse__state(auth.uid(),v_mode)||jsonb_build_object('authoritative',true));
  perform public.server_action_complete(p_session_token,'warehouse.transfer',p_request_id,v_result);
  return v_result;
end $$;

revoke all on function public.warehouse_status(uuid,uuid),public.warehouse_migrate(uuid,uuid,uuid,jsonb),public.warehouse_transfer(uuid,uuid,uuid,bigint,text,text,text,bigint) from public,anon;
grant execute on function public.warehouse_status(uuid,uuid),public.warehouse_migrate(uuid,uuid,uuid,jsonb),public.warehouse_transfer(uuid,uuid,uuid,bigint,text,text,text,bigint) to authenticated;
