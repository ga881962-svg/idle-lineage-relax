-- Read-only inspection for the pending 202608160011 history marker.
-- It intentionally does not alter Supabase migration history.
select jsonb_build_object(
  'columns', coalesce((
    select jsonb_agg(jsonb_build_object(
      'name', c.column_name,
      'type', c.data_type,
      'nullable', c.is_nullable,
      'default', c.column_default
    ) order by c.ordinal_position)
    from information_schema.columns c
    where c.table_schema = 'supabase_migrations'
      and c.table_name = 'schema_migrations'
  ), '[]'::jsonb),
  'marker_011', coalesce((
    select jsonb_agg(to_jsonb(m))
    from supabase_migrations.schema_migrations m
    where m.version = '202608160011'
  ), '[]'::jsonb)
) as migration_marker_inspect;
