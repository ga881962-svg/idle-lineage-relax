-- Diagnostic only. Run after the deterministic Phase 1 fixture; all changes
-- roll back after returning the final trace row.
begin;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
set local role authenticated;
do $$
declare token uuid:='aaaaaaaa-0000-4000-8000-000000000001'; a uuid:='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; b uuid:='cccccccc-cccc-4ccc-8ccc-cccccccccccc';
begin
  perform public.warehouse_migrate(token,a,'10000000-0000-4000-8000-000000000001','{"gold":0,"items":[]}'::jsonb);
  perform public.warehouse_transfer(token,a,'10000000-0000-4000-8000-000000000010',10,'deposit','gold',null,2000000);
  perform public.warehouse_transfer(token,b,'10000000-0000-4000-8000-000000000011',20,'withdraw','gold',null,2000000);
end $$;
reset role;
select jsonb_build_object(
  'a', (select jsonb_build_object('revision',revision,'gold',state#>>'{p,gold}','inventory',state#>'{p,inv}') from public.character_checkpoints where character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  'b', (select jsonb_build_object('revision',revision,'gold',state#>>'{p,gold}','inventory',state#>'{p,inv}') from public.character_checkpoints where character_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
  'warehouse', (select jsonb_build_object('gold',gold,'revision',revision,'items',(select coalesce(jsonb_agg(item),'[]'::jsonb) from public.account_warehouse_items where user_id=w.user_id and mode_bucket=w.mode_bucket)) from public.account_warehouses w where user_id='11111111-1111-4111-8111-111111111111' and mode_bucket='normal'),
  'ledger', (select coalesce(jsonb_agg(jsonb_build_object('action',action_type,'request',request_id,'status',status,'result',result) order by action_type,request_id),'[]'::jsonb) from public.server_action_requests where user_id='11111111-1111-4111-8111-111111111111' and action_type like 'warehouse.%')
) as phase1_gold_trace;
rollback;
