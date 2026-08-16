-- Phase 0 isolated Supabase/PostgreSQL integration suite.
-- Preconditions: an isolated project has the normal game schema, the session
-- migration, and 202608160003_server_action_foundation.sql applied. Execute as
-- the isolated project's database owner, never against production.
create or replace function pg_temp.phase0_assert(p_condition boolean, p_message text)
returns void language plpgsql as $$
begin
  if not coalesce(p_condition, false) then raise exception 'PHASE0_ASSERTION_FAILED: %', p_message; end if;
end $$;

-- Deterministic, disposable identities.  The normal auth trigger creates the
-- profile/wallet rows; the explicit inserts below make the suite independent
-- of an HTTP Auth sign-up flow.
insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-4111-8111-111111111111','authenticated','authenticated','phase0-owner@example.invalid','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-4222-8222-222222222222','authenticated','authenticated','phase0-other@example.invalid','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now())
on conflict (id) do nothing;

insert into public.player_characters(id,user_id,slot,name,class_id,level,state)
values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111',1,'Phase0Owner','knight',1,'{}'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','22222222-2222-4222-8222-222222222222',1,'Phase0Other','knight',1,'{}')
on conflict (id) do nothing;

insert into public.character_checkpoints(character_id,revision,state,saved_at)
values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',7,'{"p":{"classicMode":false}}',now()),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',3,'{"p":{"classicMode":true}}',now())
on conflict (character_id) do update set revision=excluded.revision,state=excluded.state,saved_at=excluded.saved_at;

insert into public.game_account_sessions(user_id,session_token,device_id,issued_at,last_seen_at,expires_at,invalidated_at)
values
  ('11111111-1111-4111-8111-111111111111','aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-0000-4000-8000-000000000002',now(),now(),now()+interval '15 minutes',null),
  ('22222222-2222-4222-8222-222222222222','bbbbbbbb-0000-4000-8000-000000000001','bbbbbbbb-0000-4000-8000-000000000002',now(),now(),now()+interval '15 minutes',null)
on conflict (user_id) do update set session_token=excluded.session_token,device_id=excluded.device_id,last_seen_at=excluded.last_seen_at,expires_at=excluded.expires_at,invalidated_at=null;

-- Fixtures persist for the separate concurrent-client test. Every assertion
-- below is transactional and rolls back to this known fixture state.
begin;
-- Reset only disposable suite rows and force all gates OFF.
delete from public.server_action_requests where user_id in ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222');
delete from public.server_migration_markers where user_id in ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222');
update public.server_feature_flags set enabled=false;

-- Enter the owner test user's authenticated RPC context.
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
set local role authenticated;

-- A / B: completion replay is stable, fingerprint collision is rejected.
do $$
declare v jsonb;
begin
  v:=public.server_action_begin('aaaaaaaa-0000-4000-8000-000000000001','phase0.test.action','10000000-0000-4000-8000-000000000001',repeat('a',64),'normal','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  perform pg_temp.phase0_assert(v->>'state'='running','A first request must be running');
  perform public.server_action_complete('aaaaaaaa-0000-4000-8000-000000000001','phase0.test.action','10000000-0000-4000-8000-000000000001','{"ok":true,"value":9}');
  v:=public.server_action_begin('aaaaaaaa-0000-4000-8000-000000000001','phase0.test.action','10000000-0000-4000-8000-000000000001',repeat('a',64),'normal','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  perform pg_temp.phase0_assert(v->>'state'='completed' and (v->'result'->>'value')='9','A replay must return original result');
  begin
    perform public.server_action_begin('aaaaaaaa-0000-4000-8000-000000000001','phase0.test.action','10000000-0000-4000-8000-000000000001',repeat('b',64),'normal','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    raise exception 'B collision was accepted';
  exception when others then
    perform pg_temp.phase0_assert(position('REQUEST_ID_PAYLOAD_MISMATCH' in sqlerrm)>0,'B collision error');
  end;
end $$;

-- D: a committed-but-unfinished action is never re-run.
do $$
declare v jsonb;
begin
  v:=public.server_action_begin('aaaaaaaa-0000-4000-8000-000000000001','phase0.test.running','10000000-0000-4000-8000-000000000002',repeat('c',64),'normal','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  perform pg_temp.phase0_assert(v->>'state'='running','D initial state');
  v:=public.server_action_begin('aaaaaaaa-0000-4000-8000-000000000001','phase0.test.running','10000000-0000-4000-8000-000000000002',repeat('c',64),'normal','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  perform pg_temp.phase0_assert(v->>'state'='running','D replay remains running');
end $$;

-- E / F: locked context rejects stale revisions and the next revision is server derived.
do $$
declare v jsonb;
begin
  begin
    perform public.server_action_context('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',6);
    raise exception 'E stale revision was accepted';
  exception when others then perform pg_temp.phase0_assert(position('CHECKPOINT_CONFLICT:7' in sqlerrm)>0,'E stale rejection'); end;
  v:=public.server_action_context('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',7);
  perform pg_temp.phase0_assert((v->>'revision')::bigint=7 and public.server_action_next_revision((v->>'revision')::bigint)=8,'F derived revision');
end $$;

-- G / H: feature gate rejects while OFF and accepts once the server flips it ON.
do $$
begin
  begin
    perform public.server_action_validate('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',7,'warehouse_server_authoritative');
    raise exception 'G disabled flag was accepted';
  exception when others then perform pg_temp.phase0_assert(position('FEATURE_DISABLED' in sqlerrm)>0,'G flag off'); end;
end $$;
reset role;
update public.server_feature_flags set enabled=true where flag_key='warehouse_server_authoritative';
set local role authenticated;
do $$ declare v jsonb; begin
  v:=public.server_action_validate('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',7,'warehouse_server_authoritative');
  perform pg_temp.phase0_assert(v->>'modeBucket'='normal','H flag on context');
end $$;

-- I / J / K / O: migration scope is account+mode+kind, completion replays, and source changes fail.
do $$
declare v jsonb;
begin
  v:=public.server_migration_begin('aaaaaaaa-0000-4000-8000-000000000001','normal','phase0.test.migration','20000000-0000-4000-8000-000000000001',repeat('d',64));
  perform pg_temp.phase0_assert(v->>'state'='running','I first marker');
  perform public.server_migration_complete('aaaaaaaa-0000-4000-8000-000000000001','normal','phase0.test.migration','20000000-0000-4000-8000-000000000001','{"migrated":1}');
  v:=public.server_migration_begin('aaaaaaaa-0000-4000-8000-000000000001','normal','phase0.test.migration','20000000-0000-4000-8000-000000000002',repeat('d',64));
  perform pg_temp.phase0_assert(v->>'state'='completed' and (v->'metadata'->>'migrated')='1','J completed replay');
  begin
    perform public.server_migration_begin('aaaaaaaa-0000-4000-8000-000000000001','normal','phase0.test.migration','20000000-0000-4000-8000-000000000003',repeat('e',64));
    raise exception 'K source mismatch was accepted';
  exception when others then perform pg_temp.phase0_assert(position('MIGRATION_SOURCE_MISMATCH' in sqlerrm)>0,'K source mismatch'); end;
  v:=public.server_migration_begin('aaaaaaaa-0000-4000-8000-000000000001','classic','phase0.test.migration','20000000-0000-4000-8000-000000000004',repeat('d',64));
  perform pg_temp.phase0_assert(v->>'state'='running','O mode isolation');
end $$;

-- L: a representative domain revision update and its ledger insert both roll
-- back when an action raises.  No partial Phase-0 state remains.
reset role;
do $$
begin
  begin
    perform set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
    set local role authenticated;
    perform public.server_action_begin('aaaaaaaa-0000-4000-8000-000000000001','phase0.test.rollback','30000000-0000-4000-8000-000000000001',repeat('f',64),'normal','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    reset role;
    update public.character_checkpoints set revision=8 where character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    raise exception 'intentional rollback';
  exception when others then null;
  end;
  perform pg_temp.phase0_assert((select revision=7 from public.character_checkpoints where character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),'L checkpoint rollback');
  perform pg_temp.phase0_assert(not exists(select 1 from public.server_action_requests where request_id='30000000-0000-4000-8000-000000000001'),'L ledger rollback');
end $$;

-- M / security exposure.  User two cannot use user one's character; anon has
-- no direct table or helper execute permission.  Run this while database owner
-- is inspecting privileges rather than trusting an application client.
select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
set local role authenticated;
do $$ begin
  begin
    perform public.server_action_context('bbbbbbbb-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',7);
    raise exception 'M cross-account context was accepted';
  exception when others then perform pg_temp.phase0_assert(position('CHARACTER_NOT_FOUND' in sqlerrm)>0,'M ownership'); end;
end $$;
reset role;
select pg_temp.phase0_assert(not has_table_privilege('anon','public.server_action_requests','select,insert,update,delete'),'M anon table privileges');
select pg_temp.phase0_assert(not has_table_privilege('authenticated','public.server_action_requests','select,insert,update,delete'),'M authenticated table privileges');
select pg_temp.phase0_assert(not has_function_privilege('anon','public.server_action_begin(uuid,text,uuid,text,text,uuid)','execute'),'M anon RPC privilege');
select pg_temp.phase0_assert((select count(*)=3 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('server_feature_flags','server_action_requests','server_migration_markers') and c.relrowsecurity),'M RLS enabled');
select pg_temp.phase0_assert((select count(*)=8 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('server_action_context','server_action_require_flag','server_action_validate','server_action_begin','server_action_complete','server_action_fail','server_migration_begin','server_migration_complete') and p.prosecdef),'M SECURITY DEFINER helpers');
select pg_temp.phase0_assert((select count(*)=8 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('server_action_context','server_action_require_flag','server_action_validate','server_action_begin','server_action_complete','server_action_fail','server_migration_begin','server_migration_complete') and p.proconfig @> array['search_path=public']),'M SECURITY DEFINER search_path');
select pg_temp.phase0_assert((select count(distinct p.proowner)=1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('server_action_context','server_action_require_flag','server_action_validate','server_action_begin','server_action_complete','server_action_fail','server_migration_begin','server_migration_complete')),'M common function owner');

rollback;
select jsonb_build_object('phase0_single_session_assertions','PASS','covered','A,B,D,E,F,G,H,I,J,K,L,M,O') as phase0_test_result;
