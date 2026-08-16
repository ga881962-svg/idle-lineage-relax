-- Diagnostic only. Run after phase1-warehouse-fixture.sql on the isolated DB.
-- Player calls run as authenticated.  Every authoritative-table snapshot is
-- made only after RESET ROLE, by the privileged CLI test context.  No grants,
-- RLS policies, or production functions are changed by this harness.
begin;
create temp table pg_temp.phase1_gold_trace(step text primary key, detail jsonb not null);

-- A: fixture snapshot, taken before impersonating the player.
insert into pg_temp.phase1_gold_trace
select 'A.fixture_initial',jsonb_build_object(
  'a',jsonb_build_object('revision',a.revision,'gold',a.state#>>'{p,gold}','inventory',a.state#>'{p,inv}','fullState',a.state),
  'warehouse',coalesce(w.detail,'null'::jsonb),
  'ledger',coalesce(l.detail,'[]'::jsonb)
)
from public.character_checkpoints a
left join lateral (select jsonb_build_object('gold',x.gold,'revision',x.revision,'items',(select coalesce(jsonb_agg(i.item order by i.item_uid),'[]'::jsonb) from public.account_warehouse_items i where i.user_id=x.user_id and i.mode_bucket=x.mode_bucket)) detail from public.account_warehouses x where x.user_id='11111111-1111-4111-8111-111111111111' and x.mode_bucket='normal') w on true
cross join lateral (select coalesce(jsonb_agg(jsonb_build_object('actionType',r.action_type,'requestId',r.request_id,'status',r.status,'requestHash',r.request_hash,'result',r.result,'errorCode',r.error_code) order by r.action_type,r.request_id),'[]'::jsonb) detail from public.server_action_requests r where r.user_id='11111111-1111-4111-8111-111111111111' and r.action_type in ('warehouse.migrate','warehouse.transfer','checkpoint.save')) l
where a.character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
set local role authenticated;
-- This rejection is required: authenticated users must not read the backing
-- warehouse item table directly.  Only the SECURITY DEFINER RPC may do so.
do $$
begin
  begin
    perform 1 from public.account_warehouse_items limit 1;
    perform set_config('phase1.trace.item_select','UNEXPECTED_ALLOWED',true);
  exception when insufficient_privilege then
    perform set_config('phase1.trace.item_select','DENIED',true);
  end;
end $$;
select set_config('phase1.trace.migrate_result',public.warehouse_migrate('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','10000000-0000-4000-8000-000000000001','{"gold":0,"items":[]}'::jsonb)::text,true);
reset role;

-- B: migration result and its committed authoritative state.
insert into pg_temp.phase1_gold_trace
select 'B.after_warehouse_migrate',jsonb_build_object(
  'rpcResult',coalesce(nullif(current_setting('phase1.trace.migrate_result',true),''),'null')::jsonb,
  'authenticatedDirectItemSelect',current_setting('phase1.trace.item_select',true),
  'a',jsonb_build_object('revision',a.revision,'gold',a.state#>>'{p,gold}','inventory',a.state#>'{p,inv}','fullState',a.state),
  'warehouse',jsonb_build_object('gold',w.gold,'revision',w.revision,'items',(select coalesce(jsonb_agg(i.item order by i.item_uid),'[]'::jsonb) from public.account_warehouse_items i where i.user_id=w.user_id and i.mode_bucket=w.mode_bucket)),
  'ledger',(select coalesce(jsonb_agg(jsonb_build_object('actionType',r.action_type,'requestId',r.request_id,'status',r.status,'requestHash',r.request_hash,'result',r.result,'errorCode',r.error_code) order by r.action_type,r.request_id),'[]'::jsonb) from public.server_action_requests r where r.user_id=w.user_id and r.action_type in ('warehouse.migrate','warehouse.transfer','checkpoint.save'))
)
from public.character_checkpoints a join public.account_warehouses w on w.user_id='11111111-1111-4111-8111-111111111111' and w.mode_bucket='normal'
where a.character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

set local role authenticated;
select set_config('phase1.trace.deposit_result',public.warehouse_transfer('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','10000000-0000-4000-8000-000000000010',10,'deposit','gold',null,2000000)::text,true);
reset role;

-- C: deposit must have advanced A exactly 10 -> 11.
insert into pg_temp.phase1_gold_trace
select 'C.after_A_deposit',jsonb_build_object(
  'rpcResult',coalesce(nullif(current_setting('phase1.trace.deposit_result',true),''),'null')::jsonb,
  'a',jsonb_build_object('revision',a.revision,'gold',a.state#>>'{p,gold}','inventory',a.state#>'{p,inv}','fullState',a.state),
  'warehouse',jsonb_build_object('gold',w.gold,'revision',w.revision,'items',(select coalesce(jsonb_agg(i.item order by i.item_uid),'[]'::jsonb) from public.account_warehouse_items i where i.user_id=w.user_id and i.mode_bucket=w.mode_bucket)),
  'ledger',(select coalesce(jsonb_agg(jsonb_build_object('actionType',r.action_type,'requestId',r.request_id,'status',r.status,'requestHash',r.request_hash,'result',r.result,'errorCode',r.error_code) order by r.action_type,r.request_id),'[]'::jsonb) from public.server_action_requests r where r.user_id=w.user_id and r.action_type in ('warehouse.migrate','warehouse.transfer','checkpoint.save'))
)
from public.character_checkpoints a join public.account_warehouses w on w.user_id='11111111-1111-4111-8111-111111111111' and w.mode_bucket='normal'
where a.character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

set local role authenticated;
select set_config('phase1.trace.withdraw_result',public.warehouse_transfer('aaaaaaaa-0000-4000-8000-000000000001','cccccccc-cccc-4ccc-8ccc-cccccccccccc','10000000-0000-4000-8000-000000000011',20,'withdraw','gold',null,2000000)::text,true);
reset role;

-- D is the exact committed state just before stale checkpoint_save.
insert into pg_temp.phase1_gold_trace
select 'D.before_stale_checkpoint_save',jsonb_build_object(
  'withdrawRpcResult',coalesce(nullif(current_setting('phase1.trace.withdraw_result',true),''),'null')::jsonb,
  'a',jsonb_build_object('revision',a.revision,'gold',a.state#>>'{p,gold}','inventory',a.state#>'{p,inv}','fullState',a.state),
  'b',jsonb_build_object('revision',b.revision,'gold',b.state#>>'{p,gold}','inventory',b.state#>'{p,inv}','fullState',b.state),
  'warehouse',jsonb_build_object('gold',w.gold,'revision',w.revision,'items',(select coalesce(jsonb_agg(i.item order by i.item_uid),'[]'::jsonb) from public.account_warehouse_items i where i.user_id=w.user_id and i.mode_bucket=w.mode_bucket)),
  'ledger',(select coalesce(jsonb_agg(jsonb_build_object('actionType',r.action_type,'requestId',r.request_id,'status',r.status,'requestHash',r.request_hash,'result',r.result,'errorCode',r.error_code) order by r.action_type,r.request_id),'[]'::jsonb) from public.server_action_requests r where r.user_id=w.user_id and r.action_type in ('warehouse.migrate','warehouse.transfer','checkpoint.save'))
)
from public.character_checkpoints a
join public.character_checkpoints b on b.character_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'
join public.account_warehouses w on w.user_id='11111111-1111-4111-8111-111111111111' and w.mode_bucket='normal'
where a.character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

set local role authenticated;
do $$
declare v_stale jsonb; v_result jsonb; v_error text;
begin
  -- Reconstruct fixture revision-10 state without reading warehouse tables.
  -- It is deliberately the full old player state with gold, stack and UID item.
  v_stale := '{"p":{"classicMode":false,"gold":4672844,"inv":[{"id":"test_stack","uid":"phase1-stack-a","cnt":100},{"id":"test_weapon","uid":"phase1-equip-a","cnt":1,"en":12,"bless":1,"element":"fire","option":{"crit":3},"seteff":"sherine"}]}}'::jsonb;
  begin
    v_result := public.checkpoint_save('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',10,'10000000-0000-4000-8000-000000000101',v_stale);
  exception when others then
    v_error := sqlerrm;
  end;
  perform set_config('phase1.trace.stale_result',coalesce(v_result,'null'::jsonb)::text,true);
  perform set_config('phase1.trace.stale_error',coalesce(v_error,''),true);
end $$;
reset role;

-- E contains only the player-RPC outcome; F is the post-call authoritative DB.
insert into pg_temp.phase1_gold_trace values ('E.stale_checkpoint_save_result',jsonb_build_object(
  'expectedRevision',10,
  'rpcResult',coalesce(nullif(current_setting('phase1.trace.stale_result',true),''),'null')::jsonb,
  'error',nullif(current_setting('phase1.trace.stale_error',true),'')
));
insert into pg_temp.phase1_gold_trace
select 'F.after_stale_checkpoint_save',jsonb_build_object(
  'a',jsonb_build_object('revision',a.revision,'gold',a.state#>>'{p,gold}','inventory',a.state#>'{p,inv}','fullState',a.state),
  'b',jsonb_build_object('revision',b.revision,'gold',b.state#>>'{p,gold}','inventory',b.state#>'{p,inv}','fullState',b.state),
  'warehouse',jsonb_build_object('gold',w.gold,'revision',w.revision,'items',(select coalesce(jsonb_agg(i.item order by i.item_uid),'[]'::jsonb) from public.account_warehouse_items i where i.user_id=w.user_id and i.mode_bucket=w.mode_bucket)),
  'ledger',(select coalesce(jsonb_agg(jsonb_build_object('actionType',r.action_type,'requestId',r.request_id,'status',r.status,'requestHash',r.request_hash,'result',r.result,'errorCode',r.error_code) order by r.action_type,r.request_id),'[]'::jsonb) from public.server_action_requests r where r.user_id=w.user_id and r.action_type in ('warehouse.migrate','warehouse.transfer','checkpoint.save'))
)
from public.character_checkpoints a
join public.character_checkpoints b on b.character_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'
join public.account_warehouses w on w.user_id='11111111-1111-4111-8111-111111111111' and w.mode_bucket='normal'
where a.character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
commit;

select jsonb_object_agg(step,detail order by step) as phase1_gold_trace from pg_temp.phase1_gold_trace;
