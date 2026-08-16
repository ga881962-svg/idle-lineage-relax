-- READ ONLY production schema inspection.  No DDL/DML/SET ROLE statements.
-- This file is intentionally a single SELECT so Supabase CLI JSON output is
-- complete even when it only renders the final result set.
with target as (
  select c.oid,c.relowner,c.relrowsecurity,c.relforcerowsecurity,c.relacl
  from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relname='character_event_log' and c.relkind='r'
), target_constraints as (
  select con.oid,con.conname,con.contype,pg_catalog.pg_get_constraintdef(con.oid,true) definition
  from pg_catalog.pg_constraint con where con.conrelid=(select oid from target)
), target_functions as (
  select p.oid,n.nspname,p.proname,pg_catalog.pg_get_function_identity_arguments(p.oid) identity_args,
    p.prosecdef,p.proconfig,pg_catalog.pg_get_functiondef(p.oid) definition
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where p.prokind='f' and n.nspname='public'
    and position('character_event_log' in pg_catalog.pg_get_functiondef(p.oid))>0
)
select jsonb_build_object(
  'exists',exists(select 1 from target),
  'table',coalesce((select jsonb_build_object('owner',pg_catalog.pg_get_userbyid(relowner),'rlsEnabled',relrowsecurity,'rlsForced',relforcerowsecurity) from target),'null'::jsonb),
  'columns',coalesce((select jsonb_agg(jsonb_build_object('name',c.column_name,'dataType',c.data_type,'udtSchema',c.udt_schema,'udtName',c.udt_name,'nullable',c.is_nullable,'default',c.column_default,'identity',c.is_identity,'identityGeneration',c.identity_generation,'generated',c.is_generated,'generationExpression',c.generation_expression) order by c.ordinal_position) from information_schema.columns c where c.table_schema='public' and c.table_name='character_event_log'),'[]'::jsonb),
  'constraints',coalesce((select jsonb_agg(jsonb_build_object('name',conname,'type',contype,'definition',definition) order by conname) from target_constraints),'[]'::jsonb),
  'indexes',coalesce((select jsonb_agg(jsonb_build_object('name',indexname,'definition',indexdef) order by indexname) from pg_catalog.pg_indexes where schemaname='public' and tablename='character_event_log'),'[]'::jsonb),
  'policies',coalesce((select jsonb_agg(to_jsonb(p) order by policyname) from pg_catalog.pg_policies p where p.schemaname='public' and p.tablename='character_event_log'),'[]'::jsonb),
  'grants',coalesce((select jsonb_agg(jsonb_build_object('grantee',grantee,'privilege',privilege_type,'grantable',is_grantable) order by grantee,privilege_type) from information_schema.role_table_grants where table_schema='public' and table_name='character_event_log'),'[]'::jsonb),
  'triggers',coalesce((select jsonb_agg(jsonb_build_object('name',tg.tgname,'definition',pg_catalog.pg_get_triggerdef(tg.oid,true),'enabled',tg.tgenabled) order by tg.tgname) from pg_catalog.pg_trigger tg where tg.tgrelid=(select oid from target) and not tg.tgisinternal),'[]'::jsonb),
  'sequences',coalesce((select jsonb_agg(jsonb_build_object('schema',seq_ns.nspname,'name',seq.relname,'owner',pg_catalog.pg_get_userbyid(seq.relowner)) order by seq_ns.nspname,seq.relname) from pg_catalog.pg_depend d join pg_catalog.pg_class seq on seq.oid=d.objid and seq.relkind='S' join pg_catalog.pg_namespace seq_ns on seq_ns.oid=seq.relnamespace where d.refobjid=(select oid from target)),'[]'::jsonb),
  'directDependencies',coalesce((select jsonb_agg(jsonb_build_object('class',d.classid::regclass::text,'objectOid',d.objid,'subId',d.objsubid,'type',d.deptype) order by d.classid::regclass::text,d.objid,d.objsubid) from pg_catalog.pg_depend d where d.refobjid=(select oid from target)),'[]'::jsonb),
  'dependentFunctions',coalesce((select jsonb_agg(jsonb_build_object('schema',nspname,'name',proname,'identityArgs',identity_args,'securityDefiner',prosecdef,'config',proconfig,'definition',definition) order by nspname,proname,identity_args) from target_functions),'[]'::jsonb),
  'secureSaveDefinition',(select pg_catalog.pg_get_functiondef('public.secure_save_character_checkpoint(uuid,uuid,bigint,jsonb,uuid)'::regprocedure))
) as production_character_event_log_schema;
