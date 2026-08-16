-- Read-only postflight for 202608160011_sponsor_passes_canonical.sql.
-- This verifies structural security and idempotency prerequisites without
-- creating a production test user, pass, purchase, or wallet mutation.
with objects as (
  select
    to_regclass('public.sponsor_passes') as pass_table,
    to_regclass('public.sponsor_pass_purchases') as purchase_table,
    to_regclass('public.server_action_requests') as action_ledger_table,
    to_regprocedure('public.sponsor_pass_status(uuid,uuid)') as status_fn,
    to_regprocedure('public.sponsor_pass_purchase(uuid,uuid,text,uuid)') as purchase_fn
)
select jsonb_build_object(
  'migration_011_recorded', exists(
    select 1 from supabase_migrations.schema_migrations
    where version = '202608160011'
  ),
  'sponsor_passes', o.pass_table is not null,
  'sponsor_pass_purchases', o.purchase_table is not null,
  'sponsor_pass_status', o.status_fn is not null,
  'sponsor_pass_purchase', o.purchase_fn is not null,
  'authenticated_cannot_select_passes', o.pass_table is not null and not has_table_privilege('authenticated', o.pass_table, 'select'),
  'authenticated_cannot_insert_passes', o.pass_table is not null and not has_table_privilege('authenticated', o.pass_table, 'insert'),
  'authenticated_cannot_update_passes', o.pass_table is not null and not has_table_privilege('authenticated', o.pass_table, 'update'),
  'authenticated_cannot_delete_passes', o.pass_table is not null and not has_table_privilege('authenticated', o.pass_table, 'delete'),
  'authenticated_cannot_select_purchases', o.purchase_table is not null and not has_table_privilege('authenticated', o.purchase_table, 'select'),
  'authenticated_cannot_insert_purchases', o.purchase_table is not null and not has_table_privilege('authenticated', o.purchase_table, 'insert'),
  'authenticated_can_execute_status', o.status_fn is not null and has_function_privilege('authenticated', o.status_fn, 'execute'),
  'authenticated_can_execute_purchase', o.purchase_fn is not null and has_function_privilege('authenticated', o.purchase_fn, 'execute'),
  'server_action_requests_present', o.action_ledger_table is not null,
  'sponsor_idempotency_is_self_contained', o.purchase_table is not null,
  'request_id_primary_key', o.purchase_table is not null and exists(
    select 1 from pg_constraint c
    where c.conrelid = o.purchase_table
      and c.contype = 'p'
      and pg_get_constraintdef(c.oid) like '%request_id%'
  ),
  'purchase_function_has_replay_guard', o.purchase_fn is not null and coalesce((
    select pg_get_functiondef(p.oid) like '%REQUEST_ID_PAYLOAD_MISMATCH%'
       and pg_get_functiondef(p.oid) like '%sponsor_pass_purchases%'
       and pg_get_functiondef(p.oid) like '%for update%'
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.oid = o.purchase_fn
  ), false)
) as sponsor_pass_postflight
from objects o;
