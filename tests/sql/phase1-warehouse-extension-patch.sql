-- Isolated-test-only repair for the already-applied pre-fix 202608160004.
-- It alters only the two Phase 1 function definitions; it is not a migration
-- and must never be run against production.
do $$
declare d text;
begin
  select pg_get_functiondef('public.warehouse_migrate(uuid,uuid,uuid,jsonb)'::regprocedure) into d;
  d:=replace(d,
    'encode(digest(p_legacy::text,''sha256''),''hex'')',
    'pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_legacy::text,''UTF8''::name),''sha256''::text),''hex''::text)');
  execute d;

  select pg_get_functiondef('public.warehouse_transfer(uuid,uuid,uuid,bigint,text,text,text,bigint)'::regprocedure) into d;
  d:=replace(d,
    'encode(digest(jsonb_build_object(''characterId'',p_character_id,''revision'',p_expected_revision,''direction'',p_direction,''asset'',p_asset,''itemUid'',p_item_uid,''quantity'',p_quantity)::text,''sha256''),''hex'')',
    'pg_catalog.encode(extensions.digest(pg_catalog.convert_to(jsonb_build_object(''characterId'',p_character_id,''revision'',p_expected_revision,''direction'',p_direction,''asset'',p_asset,''itemUid'',p_item_uid,''quantity'',p_quantity)::text,''UTF8''::name),''sha256''::text),''hex''::text)');
  d:=replace(d,'gen_random_uuid()','pg_catalog.gen_random_uuid()');
  execute d;
end $$;

select json_build_object(
  'warehouse_migrate_search_path',(select p.proconfig @> array['search_path=public'] from pg_proc p where p.oid='public.warehouse_migrate(uuid,uuid,uuid,jsonb)'::regprocedure),
  'warehouse_transfer_search_path',(select p.proconfig @> array['search_path=public'] from pg_proc p where p.oid='public.warehouse_transfer(uuid,uuid,uuid,bigint,text,text,text,bigint)'::regprocedure),
  'qualified_digest',(select position('extensions.digest' in pg_get_functiondef('public.warehouse_migrate(uuid,uuid,uuid,jsonb)'::regprocedure))>0 and position('extensions.digest' in pg_get_functiondef('public.warehouse_transfer(uuid,uuid,uuid,bigint,text,text,text,bigint)'::regprocedure))>0)
) as phase1_extension_patch;
