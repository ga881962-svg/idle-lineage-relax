-- Gold + inventory authoritative foundation.
--
-- Generic checkpoint state is a compatibility projection.  Once both the
-- warehouse and inventory authority flags are enabled for a migrated mode,
-- its p.gold and p.inv sections are server-owned: checkpoint_save preserves
-- the last server value instead of trusting a browser replacement.  The
-- extra inventory flag is deliberate rollout safety.  Enabling warehouse
-- authority alone must not silently freeze every legacy combat/drop path
-- before their server actions have been migrated.

create table if not exists public.character_asset_uid_owners (
  item_uid text primary key,
  owner_kind text not null check (owner_kind in ('character_inventory','account_warehouse')),
  user_id uuid not null references auth.users(id) on delete cascade,
  character_id uuid references public.player_characters(id) on delete cascade,
  mode_bucket text check (mode_bucket in ('normal','classic')),
  item_fingerprint text not null check (item_fingerprint ~ '^[a-f0-9]{64}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (owner_kind='character_inventory' and character_id is not null and mode_bucket is null)
    or (owner_kind='account_warehouse' and character_id is null and mode_bucket is not null)
  )
);
create index if not exists character_asset_uid_owners_user_idx
  on public.character_asset_uid_owners(user_id,owner_kind);
alter table public.character_asset_uid_owners enable row level security;
revoke all on public.character_asset_uid_owners from anon,authenticated;

-- This internal helper is intentionally not granted to authenticated. Future
-- inventory, warehouse, crafting and loot actions must claim a UID in the
-- same transaction that moves/creates the item. A different live owner is a
-- hard error, never a last-write-wins transfer.
create or replace function public.asset_uid_owner_claim_internal(
  p_item_uid text,
  p_owner_kind text,
  p_user_id uuid,
  p_character_id uuid,
  p_mode_bucket text,
  p_item jsonb
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare v_hash text; v_existing public.character_asset_uid_owners%rowtype;
begin
  if coalesce(p_item_uid,'')='' or p_owner_kind not in ('character_inventory','account_warehouse')
    or p_user_id is null or jsonb_typeof(p_item)<>'object' then
    raise exception 'INVALID_ASSET_UID_OWNER';
  end if;
  if (p_owner_kind='character_inventory' and (p_character_id is null or p_mode_bucket is not null))
    or (p_owner_kind='account_warehouse' and (p_character_id is not null or p_mode_bucket not in ('normal','classic'))) then
    raise exception 'INVALID_ASSET_UID_OWNER';
  end if;
  v_hash:=pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_item::text,'UTF8'::name),'sha256'::text),'hex'::text);
  select * into v_existing from public.character_asset_uid_owners where item_uid=p_item_uid for update;
  if found then
    if v_existing.owner_kind<>p_owner_kind or v_existing.user_id<>p_user_id
      or v_existing.character_id is distinct from p_character_id or v_existing.mode_bucket is distinct from p_mode_bucket then
      raise exception 'ASSET_UID_ALREADY_OWNED:%',p_item_uid;
    end if;
    update public.character_asset_uid_owners set item_fingerprint=v_hash,updated_at=now() where item_uid=p_item_uid;
    return;
  end if;
  insert into public.character_asset_uid_owners(item_uid,owner_kind,user_id,character_id,mode_bucket,item_fingerprint)
  values(p_item_uid,p_owner_kind,p_user_id,p_character_id,p_mode_bucket,v_hash);
end $$;
revoke all on function public.asset_uid_owner_claim_internal(text,text,uuid,uuid,text,jsonb) from public,anon,authenticated;

create or replace function public.checkpoint__asset_isolation_active(p_user_id uuid,p_mode_bucket text)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select coalesce((select enabled from public.server_feature_flags where flag_key='warehouse_server_authoritative'),false)
     and coalesce((select enabled from public.server_feature_flags where flag_key='inventory_server_authoritative'),false)
     and public.warehouse__migration_completed(p_user_id,p_mode_bucket)
$$;

-- Always preserve legacy warehouse mirrors. When strict asset isolation is
-- active, additionally preserve server p.gold and p.inv. Other checkpoint
-- presentation/progression fields retain their existing compatibility flow.
create or replace function public.checkpoint__merge_client_state(
  p_incoming jsonb,
  p_current jsonb,
  p_preserve_assets boolean
) returns jsonb
language plpgsql
immutable
set search_path=public
as $$
declare v_result jsonb; v_incoming_p jsonb; v_current_p jsonb; v_root_mirror jsonb; v_p_mirror jsonb;
begin
  if jsonb_typeof(p_incoming)<>'object' then raise exception 'INVALID_CHECKPOINT_STATE'; end if;
  v_result:=p_incoming-array['warehouse','warehouseGold','warehouseItems'];
  v_incoming_p:=case when jsonb_typeof(v_result->'p')='object' then v_result->'p' else '{}'::jsonb end;
  v_current_p:=case when jsonb_typeof(p_current->'p')='object' then p_current->'p' else '{}'::jsonb end;
  v_incoming_p:=v_incoming_p-array['warehouse','warehouseGold','warehouseItems'];
  if p_preserve_assets then
    v_incoming_p:=v_incoming_p-array['gold','inv'];
    if v_current_p ? 'gold' then v_incoming_p:=jsonb_set(v_incoming_p,'{gold}',v_current_p->'gold',true); end if;
    if v_current_p ? 'inv' then v_incoming_p:=jsonb_set(v_incoming_p,'{inv}',v_current_p->'inv',true); end if;
  end if;
  select coalesce(jsonb_object_agg(key,value),'{}'::jsonb) into v_root_mirror
  from jsonb_each(case when jsonb_typeof(p_current)='object' then p_current else '{}'::jsonb end)
  where key=any(array['warehouse','warehouseGold','warehouseItems']);
  select coalesce(jsonb_object_agg(key,value),'{}'::jsonb) into v_p_mirror
  from jsonb_each(v_current_p)
  where key=any(array['warehouse','warehouseGold','warehouseItems']);
  return jsonb_set(v_result||v_root_mirror,'{p}',v_incoming_p||v_p_mirror,true);
end $$;

create or replace function public.checkpoint_save(
  p_session_token uuid,
  p_character_id uuid,
  p_expected_revision bigint,
  p_request_id uuid,
  p_state jsonb
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_context jsonb; v_mode text; v_checkpoint public.character_checkpoints%rowtype;
  v_known public.server_action_requests%rowtype; v_hash text; v_started jsonb;
  v_state jsonb; v_next_revision bigint; v_result jsonb; v_preserve_assets boolean;
begin
  if p_request_id is null or p_expected_revision is null or jsonb_typeof(p_state)<>'object' then raise exception 'INVALID_CHECKPOINT_SAVE'; end if;
  v_context:=public.server_action_context(p_session_token,p_character_id,null);
  v_mode:=v_context->>'modeBucket';
  select * into v_checkpoint from public.character_checkpoints where character_id=p_character_id for update;
  if not found then raise exception 'CHECKPOINT_NOT_FOUND'; end if;
  v_hash:=pg_catalog.encode(extensions.digest(pg_catalog.convert_to(jsonb_build_object('characterId',p_character_id,'expectedRevision',p_expected_revision,'state',p_state)::text,'UTF8'::name),'sha256'::text),'hex'::text);
  select * into v_known from public.server_action_requests where user_id=auth.uid() and action_type='checkpoint.save' and request_id=p_request_id for update;
  if found then
    if v_known.request_hash<>v_hash then raise exception 'REQUEST_ID_PAYLOAD_MISMATCH'; end if;
    if v_known.status='completed' then return v_known.result; end if;
    if v_known.status='failed' then raise exception '%',coalesce(v_known.error_code,'CHECKPOINT_SAVE_FAILED'); end if;
    raise exception 'ACTION_IN_PROGRESS';
  end if;
  if v_checkpoint.revision<>p_expected_revision then raise exception 'CHECKPOINT_CONFLICT:%',v_checkpoint.revision; end if;
  v_started:=public.server_action_begin(p_session_token,'checkpoint.save',p_request_id,v_hash,v_mode,p_character_id);
  if v_started->>'state'='completed' then return v_started->'result'; end if;
  if v_started->>'state'='failed' then raise exception '%',coalesce(v_started->>'errorCode','CHECKPOINT_SAVE_FAILED'); end if;
  v_preserve_assets:=public.checkpoint__asset_isolation_active(auth.uid(),v_mode);
  v_state:=public.checkpoint__merge_client_state(p_state,v_checkpoint.state,v_preserve_assets);
  v_next_revision:=public.server_action_next_revision(v_checkpoint.revision);
  update public.character_checkpoints set state=v_state,revision=v_next_revision,saved_at=now() where character_id=p_character_id;
  v_result:=jsonb_build_object('revision',v_next_revision,'assetsPreserved',v_preserve_assets);
  perform public.server_action_complete(p_session_token,'checkpoint.save',p_request_id,v_result);
  return v_result;
end $$;

revoke all on function public.checkpoint__asset_isolation_active(uuid,text),public.checkpoint__merge_client_state(jsonb,jsonb,boolean) from public,anon,authenticated;
revoke all on function public.checkpoint_save(uuid,uuid,bigint,uuid,jsonb) from public,anon;
grant execute on function public.checkpoint_save(uuid,uuid,bigint,uuid,jsonb) to authenticated;
