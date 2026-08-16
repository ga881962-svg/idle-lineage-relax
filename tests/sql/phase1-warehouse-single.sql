-- Phase 1 isolated single-backend assertions.  Player RPC calls run as
-- authenticated; all backing-table assertions run only after RESET ROLE.
-- The enclosing transaction rolls every test mutation back.
begin;
create or replace function pg_temp.phase1_assert(p_condition boolean,p_message text)
returns void language plpgsql as $$ begin if not coalesce(p_condition,false) then raise exception 'PHASE1_ASSERTION_FAILED: %',p_message; end if; end $$;

-- Privileged contract/security checks, before impersonating the fixture user.
select pg_temp.phase1_assert(exists(
  select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='checkpoint_save'
    and pg_catalog.pg_get_function_identity_arguments(p.oid)='p_session_token uuid, p_character_id uuid, p_expected_revision bigint, p_request_id uuid, p_state jsonb'
    and p.prosecdef and exists(select 1 from unnest(coalesce(p.proconfig,'{}'::text[])) c where c='search_path=public')
),'checkpoint_save signature/security/search_path');
select pg_temp.phase1_assert(has_function_privilege('authenticated','public.checkpoint_save(uuid,uuid,bigint,uuid,jsonb)','EXECUTE'),'checkpoint_save authenticated execute');
select pg_temp.phase1_assert(not has_table_privilege('authenticated','public.account_warehouse_items','SELECT'),'warehouse item table not directly readable by authenticated');
select pg_temp.phase1_assert(not has_table_privilege('authenticated','public.server_action_requests','SELECT'),'action ledger not directly readable by authenticated');
select pg_temp.phase1_assert(not has_table_privilege('authenticated','public.character_asset_uid_owners','SELECT'),'UID ownership registry not directly readable by authenticated');
select pg_temp.phase1_assert(not has_function_privilege('authenticated','public.asset_uid_owner_claim_internal(text,text,uuid,uuid,text,jsonb)','EXECUTE'),'UID ownership claim is internal only');
select pg_temp.phase1_assert(coalesce((select relrowsecurity from pg_catalog.pg_class where oid='public.server_action_requests'::regclass),false),'action ledger RLS enabled');
select pg_temp.phase1_assert((select revision=10 and (state#>>'{p,gold}')::bigint=4672844 from public.character_checkpoints where character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),'fixture A state');
select pg_temp.phase1_assert((select revision=20 and (state#>>'{p,gold}')::bigint=100 from public.character_checkpoints where character_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'),'fixture B state');

select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
set local role authenticated;
do $$
declare
  token uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
  a uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  b uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  initial_state jsonb := '{"p":{"classicMode":false,"gold":4672844,"inv":[{"id":"test_stack","uid":"phase1-stack-a","cnt":100},{"id":"test_weapon","uid":"phase1-equip-a","cnt":1,"en":12,"bless":1,"element":"fire","option":{"crit":3},"seteff":"sherine"}]}}'::jsonb;
  after_gold_state jsonb := '{"p":{"classicMode":false,"gold":2672844,"inv":[{"id":"test_stack","uid":"phase1-stack-a","cnt":100},{"id":"test_weapon","uid":"phase1-equip-a","cnt":1,"en":12,"bless":1,"element":"fire","option":{"crit":3},"seteff":"sherine"}]}}'::jsonb;
  current_state jsonb := '{"p":{"classicMode":false,"gold":2672844,"inv":[{"id":"test_stack","uid":"phase1-stack-a","cnt":60}]}}'::jsonb;
  forged_state jsonb := '{"p":{"classicMode":false,"gold":99999999,"inv":[{"id":"test_stack","uid":"phase1-stack-a","cnt":999},{"id":"test_weapon","uid":"forged-latest-uid","cnt":1,"en":20,"bless":99,"element":"fire","option":{"crit":999},"seteff":"forged"}]}}'::jsonb;
  r jsonb; replay jsonb; stale_gold_error text; stale_inventory_error text; mismatch_error text; rollback_error text; migration_hash_error text;
  forged_error text; forged_result jsonb; a_revision bigint:=10; b_revision bigint:=20; replay_revision bigint; stack_warehouse_uid text; equipment_warehouse_uid text;
begin
  r:=public.warehouse_migrate(token,a,'10000000-0000-4000-8000-000000000001','{"gold":0,"items":[]}'::jsonb);
  if not coalesce((r->>'authoritative')::boolean,false) then raise exception 'MIGRATION_NOT_AUTHORITATIVE'; end if;

  replay_revision:=a_revision;
  r:=public.warehouse_transfer(token,a,'10000000-0000-4000-8000-000000000010',a_revision,'deposit','gold',null,2000000);
  if (r->>'revision')::bigint<>11 or (r#>>'{state,p,gold}')::bigint<>2672844 or (r#>>'{warehouse,gold}')::bigint<>2000000 then raise exception 'A_DEPOSIT_RESULT_INVALID'; end if;
  a_revision:=(r->>'revision')::bigint;
  replay:=public.warehouse_transfer(token,a,'10000000-0000-4000-8000-000000000010',replay_revision,'deposit','gold',null,2000000);
  if replay<>r then raise exception 'DUPLICATE_DEPOSIT_NOT_REPLAYED'; end if;
  r:=public.warehouse_transfer(token,b,'10000000-0000-4000-8000-000000000011',b_revision,'withdraw','gold',null,2000000);
  if (r#>>'{state,p,gold}')::bigint<>2000100 or (r#>>'{warehouse,gold}')::bigint<>0 then raise exception 'B_WITHDRAW_RESULT_INVALID'; end if;
  b_revision:=(r->>'revision')::bigint;

  begin
    perform public.checkpoint_save(token,a,10,'10000000-0000-4000-8000-000000000101',initial_state);
    raise exception 'STALE_GOLD_ACCEPTED';
  exception when others then stale_gold_error:=sqlerrm; end;
  if position('CHECKPOINT_CONFLICT:' || a_revision::text in stale_gold_error)=0 then raise exception 'STALE_GOLD_ERROR:%',stale_gold_error; end if;

  r:=public.warehouse_transfer(token,a,'10000000-0000-4000-8000-000000000020',a_revision,'deposit','item','phase1-stack-a',40);
  if (r#>>'{state,p,inv,0,cnt}')::bigint<>60 then raise exception 'STACK_DEPOSIT_RESULT_INVALID'; end if;
  a_revision:=(r->>'revision')::bigint;
  select value->>'uid' into stack_warehouse_uid from jsonb_array_elements(r#>'{warehouse,items}') where value->>'id'='test_stack' limit 1;
  if stack_warehouse_uid is null then raise exception 'STACK_WAREHOUSE_UID_MISSING'; end if;
  r:=public.warehouse_transfer(token,b,'10000000-0000-4000-8000-000000000021',b_revision,'withdraw','item',stack_warehouse_uid,10);
  if (r#>>'{state,p,inv,0,cnt}')::bigint<>10 or (r#>>'{warehouse,items,0,cnt}')::bigint<>30 then raise exception 'STACK_WITHDRAW_RESULT_INVALID'; end if;
  b_revision:=(r->>'revision')::bigint;
  r:=public.warehouse_transfer(token,a,'10000000-0000-4000-8000-000000000022',a_revision,'deposit','item','phase1-equip-a',1);
  a_revision:=(r->>'revision')::bigint;
  select value->>'uid' into equipment_warehouse_uid from jsonb_array_elements(r#>'{warehouse,items}') where value->>'id'='test_weapon' limit 1;
  if equipment_warehouse_uid is null then raise exception 'EQUIPMENT_WAREHOUSE_UID_MISSING'; end if;
  replay_revision:=b_revision;
  r:=public.warehouse_transfer(token,b,'10000000-0000-4000-8000-000000000023',b_revision,'withdraw','item',equipment_warehouse_uid,1);
  b_revision:=(r->>'revision')::bigint;
  replay:=public.warehouse_transfer(token,b,'10000000-0000-4000-8000-000000000023',replay_revision,'withdraw','item',equipment_warehouse_uid,1);
  if replay<>r or not exists(select 1 from jsonb_array_elements(r#>'{state,p,inv}') x where x.value->>'uid'='phase1-equip-a' and x.value->>'en'='12' and x.value->>'bless'='1' and x.value->>'element'='fire' and x.value#>>'{option,crit}'='3' and x.value->>'seteff'='sherine') then raise exception 'UID_METADATA_RESULT_INVALID'; end if;

  begin
    perform public.checkpoint_save(token,a,11,'10000000-0000-4000-8000-000000000102',after_gold_state);
    raise exception 'STALE_INVENTORY_ACCEPTED';
  exception when others then stale_inventory_error:=sqlerrm; end;
  if position('CHECKPOINT_CONFLICT:' || a_revision::text in stale_inventory_error)=0 then raise exception 'STALE_INVENTORY_ERROR:%',stale_inventory_error; end if;

  current_state:=jsonb_set(current_state,'{p,warehouseGold}',to_jsonb(999999999::bigint),true);
  current_state:=jsonb_set(current_state,'{p,warehouseItems}',jsonb_build_array(jsonb_build_object('uid','forged-cache','id','forged-cache')),true);
  replay_revision:=a_revision;
  r:=public.checkpoint_save(token,a,a_revision,'10000000-0000-4000-8000-000000000103',current_state);
  a_revision:=(r->>'revision')::bigint;
  replay:=public.checkpoint_save(token,a,replay_revision,'10000000-0000-4000-8000-000000000103',current_state);
  if replay<>r or (r->>'revision')::bigint<>replay_revision+1 then raise exception 'CHECKPOINT_REPLAY_INVALID'; end if;
  begin
    perform public.checkpoint_save(token,a,replay_revision,'10000000-0000-4000-8000-000000000103',jsonb_set(current_state,'{p,differentPayload}',to_jsonb(true),true));
    raise exception 'CHECKPOINT_PAYLOAD_COLLISION_ACCEPTED';
  exception when others then mismatch_error:=sqlerrm; end;
  if position('REQUEST_ID_PAYLOAD_MISMATCH' in mismatch_error)=0 then raise exception 'CHECKPOINT_PAYLOAD_MISMATCH_ERROR:%',mismatch_error; end if;

  begin
    perform public.checkpoint_save(token,a,a_revision,'10000000-0000-4000-8000-000000000104',jsonb_set(current_state,'{p,testRollback}',to_jsonb(true),true));
    raise exception 'FORCE_CHECKPOINT_ROLLBACK';
  exception when others then rollback_error:=sqlerrm; end;
  if position('FORCE_CHECKPOINT_ROLLBACK' in rollback_error)=0 then raise exception 'CHECKPOINT_ROLLBACK_SETUP_FAILED:%',rollback_error; end if;

  forged_result:=public.checkpoint_save(token,a,a_revision,'10000000-0000-4000-8000-000000000105',forged_state);
  a_revision:=(forged_result->>'revision')::bigint;
  if not coalesce((forged_result->>'assetsPreserved')::boolean,false) then raise exception 'FORGED_ASSET_ISOLATION_DISABLED'; end if;

  begin
    perform public.warehouse_transfer(token,a,'10000000-0000-4000-8000-000000000010',replay_revision,'deposit','gold',null,1999999);
    raise exception 'WAREHOUSE_REQUEST_COLLISION_ACCEPTED';
  exception when others then mismatch_error:=sqlerrm; end;
  if position('REQUEST_ID_PAYLOAD_MISMATCH' in mismatch_error)=0 then raise exception 'WAREHOUSE_PAYLOAD_MISMATCH_ERROR:%',mismatch_error; end if;
  begin
    perform public.warehouse_transfer(token,a,'10000000-0000-4000-8000-000000000024',replay_revision,'deposit','gold',null,1);
    raise exception 'WAREHOUSE_STALE_ACCEPTED';
  exception when others then mismatch_error:=sqlerrm; end;
  if position('CHECKPOINT_CONFLICT:' || a_revision::text in mismatch_error)=0 then raise exception 'WAREHOUSE_STALE_ERROR:%',mismatch_error; end if;
  r:=public.warehouse_migrate(token,a,'10000000-0000-4000-8000-000000000030','{"gold":0,"items":[]}'::jsonb);
  if not coalesce((r->>'replayed')::boolean,false) then raise exception 'MIGRATION_REPLAY_INVALID'; end if;
  begin
    perform public.warehouse_migrate(token,a,'10000000-0000-4000-8000-000000000031','{"gold":1,"items":[]}'::jsonb);
    raise exception 'MIGRATION_SOURCE_MISMATCH_ACCEPTED';
  exception when others then migration_hash_error:=sqlerrm; end;
  if position('MIGRATION_SOURCE_MISMATCH' in migration_hash_error)=0 then raise exception 'MIGRATION_SOURCE_MISMATCH_ERROR:%',migration_hash_error; end if;
  perform set_config('phase1.single.report',jsonb_build_object(
    'staleGoldError',stale_gold_error,'staleInventoryError',stale_inventory_error,
    'checkpointReplay',true,'payloadMismatchError',mismatch_error,'rollbackError',rollback_error,
    'migrationHashError',migration_hash_error,'forgedCheckpointRequestAccepted',true,
    'forgedAssetsPreserved',coalesce((forged_result->>'assetsPreserved')::boolean,false),
    'forgedCheckpointRevision',a_revision
  )::text,true);
end $$;
reset role;

-- Direct authoritative DB checks: these prove the stale calls did not restore
-- the moved stack/equipment, rather than merely proving their old state exists.
select pg_temp.phase1_assert((select revision=15 and (state#>>'{p,gold}')::bigint=2672844 and (state#>'{p,inv}')=jsonb_build_array(jsonb_build_object('id','test_stack','uid','phase1-stack-a','cnt',60)) from public.character_checkpoints where character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),'forged latest gold/stack are discarded');
select pg_temp.phase1_assert(not exists(select 1 from public.character_checkpoints c,jsonb_array_elements(c.state#>'{p,inv}') x where c.character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and x.value->>'uid'='phase1-equip-a'),'A UID equipment cannot revive after stale save');
select pg_temp.phase1_assert(not exists(select 1 from public.character_checkpoints c,jsonb_array_elements(c.state#>'{p,inv}') x where c.character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and (x.value->>'uid'='forged-latest-uid' or x.value->>'en'='20' or x.value->>'bless'='99' or x.value#>>'{option,crit}'='999' or x.value->>'seteff'='forged')),'forged latest UID/metadata are discarded');
select pg_temp.phase1_assert(exists(select 1 from public.character_checkpoints c,jsonb_array_elements(c.state#>'{p,inv}') x where c.character_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc' and x.value->>'uid'='phase1-equip-a' and x.value->>'en'='12' and x.value->>'bless'='1' and x.value->>'element'='fire' and x.value#>>'{option,crit}'='3' and x.value->>'seteff'='sherine'),'B UID metadata intact after stale save');
select pg_temp.phase1_assert((select revision=23 and (state#>>'{p,gold}')::bigint=2000100 from public.character_checkpoints where character_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'),'B remains unchanged by stale A save');
select pg_temp.phase1_assert((select gold=0 and revision=6 from public.account_warehouses where user_id='11111111-1111-4111-8111-111111111111' and mode_bucket='normal'),'warehouse remains correct after transfers');
select pg_temp.phase1_assert((select count(*)=1 and max(quantity)=30 from public.account_warehouse_items where user_id='11111111-1111-4111-8111-111111111111' and mode_bucket='normal'),'warehouse stack remainder');
select pg_temp.phase1_assert(exists(select 1 from public.server_action_requests where user_id='11111111-1111-4111-8111-111111111111' and action_type='checkpoint.save' and request_id='10000000-0000-4000-8000-000000000103' and status='completed'),'checkpoint ledger completion');
select pg_temp.phase1_assert(not exists(select 1 from public.server_action_requests where user_id='11111111-1111-4111-8111-111111111111' and action_type='checkpoint.save' and request_id='10000000-0000-4000-8000-000000000104'),'rollback probe leaves no ledger/state');
select pg_temp.phase1_assert(exists(select 1 from public.server_action_requests where user_id='11111111-1111-4111-8111-111111111111' and action_type='checkpoint.save' and request_id='10000000-0000-4000-8000-000000000105' and status='completed'),'forged request is recorded but assets are preserved');
select pg_temp.phase1_assert(not exists(select 1 from public.character_checkpoints where character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and (state#>'{p}') ?| array['warehouse','warehouseGold','warehouseItems']),'legacy warehouse mirror ignored');
select public.asset_uid_owner_claim_internal('phase1-owner-uid','character_inventory','11111111-1111-4111-8111-111111111111','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',null,'{"id":"test_weapon","uid":"phase1-owner-uid","en":12}'::jsonb);
do $$ begin
  begin
    perform public.asset_uid_owner_claim_internal('phase1-owner-uid','account_warehouse','11111111-1111-4111-8111-111111111111',null,'normal','{"id":"test_weapon","uid":"phase1-owner-uid","en":12}'::jsonb);
    raise exception 'UID owner collision accepted';
  exception when others then
    if position('ASSET_UID_ALREADY_OWNED:phase1-owner-uid' in sqlerrm)=0 then raise; end if;
  end;
end $$;
select jsonb_build_object('phase1_single_assertions','PASS','report',coalesce(nullif(current_setting('phase1.single.report',true),''),'{}')::jsonb) as phase1_single_result;
rollback;
