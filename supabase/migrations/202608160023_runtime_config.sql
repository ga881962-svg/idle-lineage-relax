-- Read-only runtime visual and UI configuration.  It creates no new tables,
-- touches no player row and preserves safe compiled fallbacks in the client.
insert into public.server_rule_catalogs
  (catalog_key, version, source_hash, payload_hash, payload, generated_at)
values
  ('runtime.config', 1,
   '50c866d1f9bd6ac26777b6ba0a216d222243d04cb013f78b0036c892a43afb88',
   '50c866d1f9bd6ac26777b6ba0a216d222243d04cb013f78b0036c892a43afb88',
   '{"monster_scale":1.0,"boss_scale":1.0,"player_scale":1.0,"mob_animation_fps":8,"ui_entry_visibility":{"black_market":true,"leaderboard":true}}'::jsonb,
   now())
on conflict (catalog_key) do update
  set version=excluded.version,
      source_hash=excluded.source_hash,
      payload_hash=excluded.payload_hash,
      payload=excluded.payload,
      generated_at=excluded.generated_at;
