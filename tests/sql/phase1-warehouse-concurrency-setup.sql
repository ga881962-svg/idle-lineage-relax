-- Committed base for each warehouse concurrency scenario: A has deposited
-- 2m gold and a UID weapon; B begins at revision 20. Run only on test DB.
begin;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
set local role authenticated;
select public.warehouse_migrate('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','20000000-0000-4000-8000-000000000001','{"gold":0,"items":[]}'::jsonb);
select public.warehouse_transfer('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','20000000-0000-4000-8000-000000000010',10,'deposit','gold',null,2000000);
select public.warehouse_transfer('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','20000000-0000-4000-8000-000000000011',11,'deposit','item','phase1-equip-a',1);
commit;
