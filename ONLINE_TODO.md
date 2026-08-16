# Online canonical system — remaining work

The game now targets the online build only. Server state and server rules are
the authoritative source; the frontend is limited to input, UI and rendering.

## Release gate

- Apply and verify the Phase 0–1 migrations in the isolated Supabase project.
- Run the two-backend warehouse and market concurrency suites: duplicate
  request, simultaneous UID withdrawal/purchase, gold overdraw, migration
  race, deadlock and lock-timeout checks.
- Perform the online gameplay acceptance checklist: checkpoint restore,
  character switching, warehouse gold/stack/UID transfer, market
  list/cancel/buy/reclaim, logout and reload persistence.
- Only after those pass: apply 009 legacy-RPC revoke regression, then 010
  legacy-RPC removal regression. Production remains untouched until the test
  project has passed.

## Server-authoritative migration roadmap

- Complete warehouse consume-and-reward actions for crafting, quests, NPC
  exchanges and enhancement as atomic server actions. Do not let the client
  consume material then grant a reward.
- Finish inventory/gold authority rollout after all normal asset writers have
  server actions. Generic checkpoint writes must never be an asset mutation
  channel.
- Move pet and ally progression to authoritative server state and include it
  in immutable departure snapshots.
- Complete offline hunting settlement from immutable snapshots and versioned
  catalogs only. Exclude live-world/PVP/card/transformation effects without
  server state.
- Progressively move combat, drop, EXP-curve, recipe, quest, enhancement,
  market and sponsor rules to a shared server canonical catalog/source.

## Online gameplay follow-up

- Finish server-backed ally roster/progression UI; current local roster must
  not become an authoritative write path.
- Verify the new Lv.1–75 curve in a real session, including level-50 growth,
  level-75 cap and character-select level display after deploying idle-api.
- Review mobile battle UI on real iOS/Android devices: safe-area spacing,
  battle targeting, potion use, teleport, bag/settings/log navigation and
  portrait/landscape layout.
- Add real online monitoring/diagnostics for checkpoint conflicts, action
  ledger replays and rejected ownership collisions.

## Content/UI backlog

- Player-facing equipment visual polish beyond the completed icon redraw
  flicker fix.
- Finish wiki coverage and review map/drop reverse lookup content.
- Continue GM console only through server-authorized mutation routes.
- Review world-chat retention/moderation and global channel lifecycle.

## Explicitly deferred

- No single-player, localStorage authority or legacy-client compatibility.
- No production migration, Edge deployment or feature-flag rollout until the
  isolated test gate above is complete.
