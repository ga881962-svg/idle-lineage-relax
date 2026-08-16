# Phase 0 server-action foundation

## Lock order

All server actions must acquire locks only in this order:

1. Active session validation (no row lock retained).
2. Account-scoped rows (`account_wallets`, account flags/migration marker).
3. Character checkpoint.
4. Account warehouse.
5. Inventory/UID rows or progression rows.
6. Domain-specific rows (market listing, quest state, etc.).
7. Action request ledger.

When an action does not need a category, it skips it; it never changes the
order. The request ledger can be read before locks for an immediate completed
response, but its final row lock follows the listed order.

For a character-scoped action, the required common sequence is:

1. `server_action_validate(session, character, expectedRevision, flag)`;
2. lock any remaining account/domain rows in the order above;
3. `server_action_begin(session, ...)` as the final mutation lock;
4. perform the domain mutation and revision increment in that transaction;
5. call `server_action_complete(session, ...)`, or `server_action_fail(session, ...)` only for a
   deterministic business failure that the action intentionally records.

`server_action_context` performs the expected/current revision comparison on a
locked checkpoint; the action uses `server_action_next_revision(current)` in
the same final update. No helper accepts a client-supplied next revision.

Both migration helpers validate the active session before they create, lock, or
complete a marker. A completed marker returns its stored metadata and never
imports a client source again. The three foundation tables use RLS with no
direct client policies; only authenticated RPC execution is granted, and anon
has neither function nor table permission.

## Compatibility and rollback

Flags are server-side and default false. Enabling a flag selects a server action
for the capability; an older client receives `FEATURE_DISABLED`/upgrade errors
instead of a local-authority fallback. Disabling a flag stops new writes only;
it never reimports localStorage or rewrites migrated assets.

## Phase-0 static tests

The SQL tests require PostgreSQL and are listed in `tests/server-action-tests.md`.
The repository can run syntax/catalog checks without applying migrations.
