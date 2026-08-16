-- Phase 0 only: shared server-action infrastructure. Do not apply until reviewed.

create table if not exists public.server_feature_flags (
  flag_key text primary key,
  enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  check (flag_key in ('warehouse_server_authoritative','inventory_server_authoritative','crafting_server_actions','quest_server_actions','enhancement_server_actions','pet_server_authoritative','offline_settlement_v2'))
);
insert into public.server_feature_flags(flag_key,enabled) values
  ('warehouse_server_authoritative',false),('inventory_server_authoritative',false),('crafting_server_actions',false),('quest_server_actions',false),('enhancement_server_actions',false),('pet_server_authoritative',false),('offline_settlement_v2',false)
on conflict(flag_key) do nothing;

create table if not exists public.server_action_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  mode_bucket text not null check (mode_bucket in ('normal','classic')),
  character_id uuid references public.player_characters(id) on delete set null,
  action_type text not null check (action_type ~ '^[a-z][a-z0-9_.-]{1,96}$'),
  request_id uuid not null,
  request_hash text not null check (request_hash ~ '^[a-f0-9]{64}$'),
  status text not null check (status in ('running','completed','failed')),
  result jsonb,
  error_code text,
  error_details jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  unique(user_id,action_type,request_id)
);
create index if not exists server_action_requests_owner_idx on public.server_action_requests(user_id,created_at desc);

create table if not exists public.server_migration_markers (
  user_id uuid not null references auth.users(id) on delete cascade,
  mode_bucket text not null check (mode_bucket in ('normal','classic')),
  migration_kind text not null check (migration_kind ~ '^[a-z][a-z0-9_.-]{1,96}$'),
  status text not null check (status in ('pending','running','completed','failed')),
  request_id uuid,
  source_hash text,
  result_metadata jsonb not null default '{}'::jsonb,
  error_code text,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key(user_id,mode_bucket,migration_kind)
);

-- These tables are mutation-only through SECURITY DEFINER helpers.  There are
-- intentionally no client table policies: authenticated clients may not list,
-- insert, update, or delete ledger/marker/flag rows directly.
alter table public.server_feature_flags enable row level security;
alter table public.server_action_requests enable row level security;
alter table public.server_migration_markers enable row level security;
revoke all on public.server_feature_flags,public.server_action_requests,public.server_migration_markers from anon,authenticated;

-- Lock order is documented in SERVER_ACTION_FOUNDATION.md. This helper only
-- validates a character and returns its server-derived mode; actions still
-- acquire their affected rows in that documented order.
create or replace function public.server_action_context(p_session_token uuid,p_character_id uuid,p_expected_revision bigint default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_revision bigint; v_state jsonb; v_mode text;
begin
  perform public.assert_active_game_session(p_session_token);
  if not exists(select 1 from public.player_characters c where c.id=p_character_id and c.user_id=auth.uid()) then raise exception 'CHARACTER_NOT_FOUND'; end if;
  select revision,state into v_revision,v_state from public.character_checkpoints where character_id=p_character_id for update;
  if v_revision is null then raise exception 'CHECKPOINT_NOT_FOUND'; end if;
  if p_expected_revision is not null and p_expected_revision<>v_revision then raise exception 'CHECKPOINT_CONFLICT:%',v_revision; end if;
  v_mode:=case when coalesce((v_state#>>'{p,classicMode}')::boolean,false) then 'classic' else 'normal' end;
  return jsonb_build_object('userId',auth.uid(),'characterId',p_character_id,'modeBucket',v_mode,'revision',v_revision);
end $$;

-- Domain actions call this after locking their checkpoint row and before the
-- single update that commits both state and the new revision.
create or replace function public.server_action_next_revision(p_current_revision bigint)
returns bigint language plpgsql immutable as $$
begin
  if p_current_revision is null or p_current_revision < 0 then raise exception 'INVALID_CURRENT_REVISION'; end if;
  return p_current_revision + 1;
end $$;

create or replace function public.server_action_require_flag(p_flag_key text)
returns void language plpgsql security definer set search_path=public as $$
declare v_enabled boolean;
begin
  select enabled into v_enabled from public.server_feature_flags where flag_key=p_flag_key;
  if not found then raise exception 'UNKNOWN_FEATURE_FLAG'; end if;
  if not v_enabled then raise exception 'FEATURE_DISABLED:%',p_flag_key; end if;
end $$;

-- Common preflight for every character-scoped server action.  Domain actions
-- may add validation, but may not bypass this auth/session/ownership/revision
-- and flag gate.
create or replace function public.server_action_validate(p_session_token uuid,p_character_id uuid,p_expected_revision bigint,p_flag_key text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_context jsonb;
begin
  perform public.server_action_require_flag(p_flag_key);
  v_context:=public.server_action_context(p_session_token,p_character_id,p_expected_revision);
  return v_context;
end $$;

-- Begin only records an immutable request identity. Repeated complete actions
-- return their result; a changed payload under the same ID is always rejected.
create or replace function public.server_action_begin(p_session_token uuid,p_action_type text,p_request_id uuid,p_request_hash text,p_mode_bucket text,p_character_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.server_action_requests%rowtype;
begin
  perform public.assert_active_game_session(p_session_token);
  if p_mode_bucket not in ('normal','classic') or p_request_hash !~ '^[a-f0-9]{64}$' then raise exception 'INVALID_ACTION_REQUEST'; end if;
  insert into public.server_action_requests(user_id,mode_bucket,character_id,action_type,request_id,request_hash,status)
  values(auth.uid(),p_mode_bucket,p_character_id,p_action_type,p_request_id,p_request_hash,'running')
  on conflict(user_id,action_type,request_id) do nothing;
  select * into r from public.server_action_requests where user_id=auth.uid() and action_type=p_action_type and request_id=p_request_id for update;
  if r.request_hash<>p_request_hash then raise exception 'REQUEST_ID_PAYLOAD_MISMATCH'; end if;
  if r.status='completed' then return jsonb_build_object('state','completed','result',r.result); end if;
  if r.status='failed' then return jsonb_build_object('state','failed','errorCode',r.error_code,'errorDetails',r.error_details); end if;
  return jsonb_build_object('state','running','actionId',r.id);
end $$;

create or replace function public.server_action_complete(p_session_token uuid,p_action_type text,p_request_id uuid,p_result jsonb)
returns void language plpgsql security definer set search_path=public as $$
begin
  perform public.assert_active_game_session(p_session_token);
  update public.server_action_requests set status='completed',result=p_result,error_code=null,error_details=null,completed_at=now(),updated_at=now()
  where user_id=auth.uid() and action_type=p_action_type and request_id=p_request_id and status='running';
  if not found then raise exception 'ACTION_NOT_RUNNING'; end if;
end $$;

create or replace function public.server_action_fail(p_session_token uuid,p_action_type text,p_request_id uuid,p_error_code text,p_error_details jsonb default null)
returns void language plpgsql security definer set search_path=public as $$
begin
  perform public.assert_active_game_session(p_session_token);
  update public.server_action_requests set status='failed',error_code=p_error_code,error_details=p_error_details,completed_at=now(),updated_at=now()
  where user_id=auth.uid() and action_type=p_action_type and request_id=p_request_id and status='running';
  if not found then raise exception 'ACTION_NOT_RUNNING'; end if;
end $$;

create or replace function public.server_migration_begin(p_session_token uuid,p_mode_bucket text,p_migration_kind text,p_request_id uuid,p_source_hash text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare m public.server_migration_markers%rowtype;
begin
  perform public.assert_active_game_session(p_session_token);
  if p_mode_bucket not in ('normal','classic') or p_migration_kind !~ '^[a-z][a-z0-9_.-]{1,96}$' or p_source_hash !~ '^[a-f0-9]{64}$' then raise exception 'INVALID_MIGRATION_REQUEST'; end if;
  insert into public.server_migration_markers(user_id,mode_bucket,migration_kind,status,request_id,source_hash)
  values(auth.uid(),p_mode_bucket,p_migration_kind,'running',p_request_id,p_source_hash)
  on conflict(user_id,mode_bucket,migration_kind) do nothing;
  select * into m from public.server_migration_markers where user_id=auth.uid() and mode_bucket=p_mode_bucket and migration_kind=p_migration_kind for update;
  if m.source_hash is distinct from p_source_hash then raise exception 'MIGRATION_SOURCE_MISMATCH'; end if;
  if m.status='completed' then return jsonb_build_object('state','completed','metadata',m.result_metadata); end if;
  if m.request_id is distinct from p_request_id then raise exception 'MIGRATION_IN_PROGRESS_OR_ALREADY_ATTEMPTED'; end if;
  return jsonb_build_object('state',m.status);
end $$;

create or replace function public.server_migration_complete(p_session_token uuid,p_mode_bucket text,p_migration_kind text,p_request_id uuid,p_metadata jsonb)
returns void language plpgsql security definer set search_path=public as $$
begin
  perform public.assert_active_game_session(p_session_token);
  update public.server_migration_markers set status='completed',result_metadata=coalesce(p_metadata,'{}'::jsonb),completed_at=now(),updated_at=now()
  where user_id=auth.uid() and mode_bucket=p_mode_bucket and migration_kind=p_migration_kind and request_id=p_request_id and status='running';
  if not found then raise exception 'MIGRATION_NOT_RUNNING'; end if;
end $$;

revoke all on function public.server_action_context(uuid,uuid,bigint),public.server_action_next_revision(bigint),public.server_action_require_flag(text),public.server_action_validate(uuid,uuid,bigint,text),public.server_action_begin(uuid,text,uuid,text,text,uuid),public.server_action_complete(uuid,text,uuid,jsonb),public.server_action_fail(uuid,text,uuid,text,jsonb),public.server_migration_begin(uuid,text,text,uuid,text),public.server_migration_complete(uuid,text,text,uuid,jsonb) from public,anon;
grant execute on function public.server_action_context(uuid,uuid,bigint),public.server_action_next_revision(bigint),public.server_action_require_flag(text),public.server_action_validate(uuid,uuid,bigint,text),public.server_action_begin(uuid,text,uuid,text,text,uuid),public.server_action_complete(uuid,text,uuid,jsonb),public.server_action_fail(uuid,text,uuid,text,jsonb),public.server_migration_begin(uuid,text,text,uuid,text),public.server_migration_complete(uuid,text,text,uuid,jsonb) to authenticated;
