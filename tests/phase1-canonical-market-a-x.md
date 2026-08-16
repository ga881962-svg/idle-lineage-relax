# Phase 1 canonical market / warehouse single-backend regression

Run this only after the isolated project has applied, in order, `003`, `004`,
`005`, `006`, `007`, and `008_item_classification_catalog`. Keep
`inventory_server_authoritative=false`; this suite verifies canonical market
and UID moves, not the strict 006 rollout.

The fixture must use a canonical stack item such as `potion_heal` and a
canonical UID item such as `wpn_katana`, with a full item JSON payload
containing `uid`, `en`, `bless`, `element`, `option`, and `seteff`.

| Case | Required assertion |
| --- | --- |
| A | 6-argument `secure_market_list` removes the item, charges fee, increments seller revision, and returns state/revision. |
| B | `secure_market_buy` locks active listing, moves item to buyer, transfers wallet proceeds, increments buyer revision. |
| C | `secure_market_cancel` returns an active listing once and increments seller revision. |
| D | `secure_market_reclaim` returns each expired listing once. |
| E–H | Identical request ID/payload replays list/buy/cancel/reclaim result without another mutation. |
| I | Stack partial listing/cancel/buy maintains exact counts. |
| J–M | UID owner row moves character→market, market→seller, market→buyer, market→seller on reclaim. |
| N | A UID already owned by warehouse/market/another character is rejected. |
| O | UID JSON is byte-equivalent for `uid`, `id`, `en`, `bless`, `element`, `option`, `seteff` after every move. |
| P | Same action/request ID with a different payload raises `REQUEST_ID_PAYLOAD_MISMATCH`. |
| Q | Old checkpoint revision raises `CHECKPOINT_CONFLICT:<current>` and cannot restore gold, stack, or UID. |
| R | An injected exception after each listing/owner/wallet/checkpoint stage rolls back all rows and ledger completion. |
| S | After applying 009, legacy checkpoint and market write RPC execution is denied to `authenticated`. |
| T | `pg_get_functiondef` for canonical market functions contains no legacy event-log reference. |
| U | UID warehouse deposit changes owner `character_inventory→account_warehouse`. |
| V | UID warehouse withdraw changes owner `account_warehouse→character_inventory`. |
| W | Warehouse UID collision is rejected without changing inventory/warehouse/owner rows. |
| X | Duplicate warehouse transfer replays ledger result and does not move owner twice. |

For every action, query `character_checkpoints`, `account_warehouses`,
`account_warehouse_items`, `player_market_listings`,
`character_asset_uid_owners`, and `server_action_requests` from the privileged
test context after the authenticated RPC call.  A client role must never be
granted direct read access to these authoritative tables.
