# Server-authoritative migration architecture

## Decision

The game is now an online multiplayer game. Supabase is the authoritative
source for gameplay assets and progression. The browser is an authenticated
command client: UI, input, animation, rendering, and non-authoritative UI
preferences only. It must never grant an item, select authoritative RNG, or
persist an asset balance as truth.

This is an incremental migration. Existing gameplay remains available behind
per-phase feature flags; a phase is deployed only after its migration and
concurrency tests pass.

## A. Authoritative data boundary

| Data | Authority | Notes |
| --- | --- | --- |
| Account, session, roles | Supabase Auth / DB | Existing active-session model remains. |
| Character identity and current state | `player_characters`, `character_checkpoints` | Checkpoint remains the compatibility projection during migration. |
| Gold, inventory, equipped UID items | Server action state | Eventually normalized inventory rows; checkpoint is a read model. |
| Sponsor diamonds and passes | Server | Existing wallet/pass tables. |
| Shared warehouse | Server | Account + mode bucket, never browser storage. |
| Crafting, quests, exchanges, enhancement outcomes | Server action transaction | Server rules and RNG. |
| Pet and ally progression | Server | Pet roster rows; allies begin as checkpoint projection. |
| Marketplace and clan asset state | Server | Keep existing server systems; migrate only their remaining asset edges. |
| UI preferences, panel state, viewport | Browser localStorage | No progression or asset value. |
| Legacy local state | Read-once migration payload / backup only | Never an authoritative overwrite source. |

## B. Remaining localStorage uses

Allowed after the migration: UI preferences, selected panels, viewport and
similar display-only state, plus a read-only backup of a completed legacy
migration payload.

Not allowed: warehouse balances/items, pet roster/progression, asset inventory,
gold, rewards, RNG results, quest completion, equipment/UID ownership, or any
value that can advance a server checkpoint.

## C. Server action framework

Every state-changing action is represented by a typed action command and runs
in one database transaction:

1. Validate Supabase Auth and the active game session token.
2. Validate account/character ownership and action request schema.
3. Read an idempotency ledger entry by `(user_id, action_kind, request_id)`;
   return its stored result if present.
4. Lock the minimum affected rows in fixed order: account, character,
   warehouse, inventory/target item, progression rows.
5. Verify expected revision(s) and eligibility from server state/catalog.
6. Run server RNG where applicable, using a persisted action seed/result.
7. Consume and grant assets, mutate quest/progression state, and update only
   the affected revisions.
8. Write the immutable action result to the ledger.
9. Commit and return the authoritative state delta/revisions.

The framework must provide generic primitives internally (`consume_assets`,
`grant_items`, `advance_checkpoint`) but public RPCs are domain actions such as
`craft.execute`, `quest.submit`, `npc.exchange`, or `enhance.execute`.
Generic browser-controlled `consume` followed by a browser reward is forbidden.

## D. Dependency-based phases

| Phase | Scope | Depends on | Exit condition |
| --- | --- | --- | --- |
| 0 | Schema ownership, action ledger, feature flags, migration/rollback harness | none | Safe no-op rollout and audit trail. |
| 1 | Shared warehouse: transfer, consume, one-time import, stale revisions | 0 | A→B→A duplication and multi-device races pass tests. |
| 2 | Inventory/action transaction foundation | 0, 1 | Server can atomically consume/grant UID and stack assets. |
| 3 | Normal crafting: recipe catalog, recursive materials, server RNG | 2 | Consume + crafted result is atomic. |
| 4 | Special crafting: Demon King, Lumiel, mystic wand, slayer, other bespoke recipes | 2, 3 | Source UID/effects are preserved atomically. |
| 5 | Quests, trials and NPC exchanges | 2 | Quest state, consume and reward are atomic/idempotent. |
| 6 | Enhancement, scrolls and state-changing item actions | 2 | Server controls target UID, RNG and resulting item state. |
| 7 | Pet roster and ally progression | 0 | Stale local pet state cannot overwrite server progression. |
| 8 | Offline settlement | 1, 2, 5, 7 | Settlement only reads catalog + immutable server snapshot. |
| 9 | Retire legacy gameplay localStorage writes | all relevant phases | No authoritative local write caller remains. |

Phase 1 must begin first because it fixes the demonstrated asset duplication
boundary and supplies the row-lock/idempotency pattern used by later phases.

## E. Main artifacts by phase

- Phase 0: `server_action_requests`, action policy/feature-flag tables,
  action framework SQL helpers, Edge action router.
- Phase 1: `account_warehouses`, `account_warehouse_items`, migration marker
  table, transfer/import/status RPCs and warehouse route/UI adapter.
- Phase 2: normalized `character_inventory_items` (UID instance rows) and
  inventory revision/action helpers. Do not replace checkpoint reads until
  parity is verified.
- Phase 3-4: generated recipe catalog tables plus `craft.execute` action.
- Phase 5: generated quest/NPC exchange catalog plus `quest.submit` and
  `npc.exchange` actions.
- Phase 6: generated enhancement catalog plus `enhance.execute` action.
- Phase 7: `account_pet_rosters`, `account_pet_progression`, checkpoint ally
  projection, roster import/update APIs.
- Phase 8: versioned combat catalog, immutable departure snapshots, revised
  settlement action.

## F. Migration strategy

Migration payloads are imported only through an authenticated server RPC:

1. Scope is `(account, mode_bucket, migration_kind)`.
2. A migration marker row is inserted/locked before accepting a payload.
3. The server validates schema, UID uniqueness, item bounds, ownership and
   account/mode bucket.
4. A request ID ledger makes retry return the original result.
5. On success the server writes the imported rows and marks the migration
   completed atomically.
6. Subsequent calls, including from another old device, return
   `MIGRATION_ALREADY_COMPLETED`; they never merge again.
7. The browser may retain an encrypted/read-only backup flag, but cannot write
   it back into gameplay state.

Existing checkpoint data is migrated through server-owned projection jobs with
per-character revision checks. No bulk clearing is permitted.

## G. Rollback strategy

Each phase has three independent controls:

- **Feature flag:** route clients to the legacy-compatible read path while
  preserving server-written rows; never revert by replaying localStorage.
- **DB rollback:** additive migrations first; destructive column/table removal
  occurs only after a later verified release. Restore is a forward corrective
  migration, not a blind SQL rollback after players have mutated new state.
- **API compatibility:** old clients receive explicit upgrade/read-only errors
  for an authoritative feature instead of falling back to local writes.

For an import failure, the transaction rolls back fully and the marker remains
pending/failed with diagnostics, allowing an idempotent retry. For a completed
import, rollback means feature-flagging server reads while preserving the
server asset ledger; it never reimports browser data.

## H. Revision and locking model

Use the smallest sufficient revision domain:

- `character_checkpoints.revision`: compatibility snapshot and character-only
  state changes.
- `account_warehouses.revision`: warehouse UI/read freshness only; transfer
  still locks the row.
- `character_inventory.revision` (Phase 2): only if inventory leaves the
  checkpoint; otherwise do not invent a parallel revision.
- `account_pet_rosters.revision`: roster membership/selection.
- per-pet `progression_revision`: level/EXP changes.
- ally data initially tracks the source checkpoint revision, avoiding a third
  independent mutable truth.

Actions use expected revisions for optimistic stale-client detection, then
`FOR UPDATE` locks for correctness. Lock order is account → character →
warehouse → inventory item → pet/ally to prevent deadlocks.

## I. Idempotency model

One `server_action_requests` ledger uses `(user_id, action_kind, request_id)`
as the unique key. It records request hash, status, resulting revisions and
redacted authoritative result. A reused request ID with a different payload is
rejected. Every asset/progression action uses it: warehouse, craft, quest, NPC,
enhancement, sponsor, marketplace, settlement and claims.

## J. Primary risks

1. Reimplementing browser-only RNG/rules manually causes rule drift.
2. Migrating local data twice creates assets.
3. Partial client/server actions create consume/reward loss or duplication.
4. Normalizing inventory too early can break UI/equipment assumptions.
5. Long transactions over recursive crafting can cause contention.
6. Old clients falling back to local writes can overwrite migration state.

Mitigations are generated versioned catalogs, one-time server import markers,
single-transaction actions, additive projections, bounded action input, and
feature-gated client versions.

## K. Estimated phase size

- Small/medium: 0 and the schema-only portion of 1/7.
- Medium/large: complete Phase 1 and pet roster migration.
- Large: 2, 3, 4, 5 and 6; these change normal gameplay execution and require
  catalog parity tests.
- Large/high-risk: 8 and 9, after all prerequisites are proven.

## L. First implementation phase

Start **Phase 0**, then immediately deploy/test **Phase 1** in an isolated
environment. Phase 1 must not claim completion until warehouse import,
transfer, all server-backed consume paths selected for the phase, stale
revision handling and multi-device/idempotency tests are passing.
