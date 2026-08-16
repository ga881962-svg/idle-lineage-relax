# Gold and inventory authority transition

`p.gold` and `p.inv` are currently compatibility fields inside
`character_checkpoints.state`. They become server-owned only when both
`warehouse_server_authoritative` and `inventory_server_authoritative` are on
for a mode that has completed warehouse migration. The second flag prevents a
warehouse-only rollout from silently freezing legacy combat rewards.

## Current path classification

| Class | Paths |
| --- | --- |
| A: server action today | Warehouse migrate/transfer; market RPC mutations; offline settlement RPC (not being changed in this phase); GM service-role path. |
| B: can move to atomic server actions | kill/drop/pickup, buy/sell, potion/item consumption, quest reward/turn-in, crafting, enhancement, NPC conversion, sponsor rewards. Each needs canonical rules plus consume/reward in one transaction. |
| C: still client checkpoint writes | The browser implementations of all B paths today, auto-sell, map utility costs, pet/ally consumptions, clan/siege costs, local offline reward application, load/repair/orphan cleanup, and normal combat reward accumulation. |

## Rollout rule

Do not enable `inventory_server_authoritative` in production until each active
asset-producing or asset-consuming C path has a corresponding server action.
While it is off, generic checkpoint save remains a known trust boundary; while
it is on, generic save preserves server gold/inventory and cannot be used for
asset mutation.

## UID ownership

`character_asset_uid_owners` is the global uniqueness registry foundation.
Future character-inventory and warehouse actions must claim/release a UID in
the same transaction. A registry conflict is a hard failure. It is deliberately
not backfilled or enabled for production in this phase: doing so before all
inventory writers are server actions would create an unsafe partial authority.
