-- Repairs only the migration-history marker for an already-applied 011.
-- It never executes the migration itself and mutates no player/game data.
with required_schema as (
  select
    to_regclass('public.sponsor_passes') is not null as has_passes,
    to_regclass('public.sponsor_pass_purchases') is not null as has_purchases,
    to_regprocedure('public.sponsor_pass_status(uuid,uuid)') is not null as has_status,
    to_regprocedure('public.sponsor_pass_purchase(uuid,uuid,text,uuid)') is not null as has_purchase
), inserted as (
  insert into supabase_migrations.schema_migrations(version, name, statements)
  select '202608160011', 'sponsor_passes_canonical', null::text[]
  from required_schema
  where has_passes and has_purchases and has_status and has_purchase
  on conflict (version) do nothing
  returning version
)
select jsonb_build_object(
  'requirements_present', (select has_passes and has_purchases and has_status and has_purchase from required_schema),
  'marker_inserted_now', exists(select 1 from inserted),
  'marker_present_after', exists(
    select 1 from supabase_migrations.schema_migrations
    where version = '202608160011'
  )
) as migration_marker_repair;
