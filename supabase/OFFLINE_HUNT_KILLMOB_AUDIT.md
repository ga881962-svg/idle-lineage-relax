# Offline hunt: remaining `killMob()` rule audit

This is an implementation inventory, not a licence to approximate a rule.
`offline_hunt_settle` is intentionally not changed by this work.

## A — deterministic from catalog + immutable departure snapshot

- Base EXP/gold, `hard` non-boss gold, `boss`/`noGold`, party EXP and party reward multiplier.
- Normal, dark weapon, dark crystal, dragon, warrior and memory tables; trial-item gate and forced trial drop.
- Region/category conditions: blackstone, silver ore, holy relic and area materials.
- 50-level stage drops (`item_dantes_letter`, `item_ancient_book`, `item_chaos_key`, `item_royal_order`, `item_elf_whisper`, `item_sealed_intel`, `item_spy_report`) using main/ally stage, aggregate inventory and `_questLoot` ledger.
- Mastery proof: class boss plus `masteryQuest=active` and proof not held.
- Kari's four-item consumption and its dragonslayer exception.
- Four-dragon two independent 10% egg rolls, subject to party/sponsor drop semantics.
- Generic panacea roll, subject to boss/level/race/no-reward predicates.
- Demon Temple `flameAffinity +1` is deterministic, but is progression state rather than a loot award.

The map category/region catalog and departure snapshot now cover the *inputs* for the trial rules.  The pending settlement rewrite must apply inventory/ledger deltas atomically with its settled/checkpoint revision transaction; otherwise it must not award a controlled quest item.

## A gaps deliberately left open (so settlement is not yet safe to claim complete)

1. The shared warehouse is currently browser/local-storage state, not server authoritative. `trialItemActiveFor()` includes old same-mode warehouse stock. The snapshot records `warehouseAuthoritative=false`; a settlement must conservatively exclude any trial result whose eligibility could depend on that warehouse until a server-owned warehouse-count state exists.
2. The source's pet and ally EXP progression (`petsGainExp`, each active ally's own level multiplier) has no server-side roster/XP checkpoint or atomic target ledger. It cannot be silently folded into the main character EXP.
3. Kari's item decrement, mastery proof, stage/trial item grants, and flame-affinity increments require a settlement-side atomic character/ally checkpoint mutation. The catalog/snapshot now expose the inputs; the mutation is intentionally deferred with `offline_hunt_settle`.
4. Generic panacea and dragon egg rules are identified from `killMob()` but are not yet emitted as dedicated executable catalog rows. They must be generated from canonical source (rather than copied into SQL) in the next settlement-focused pass.

## B — requires live server world state

- `_sherine`, `_grace`, their current drop multipliers and Sherine crystal logic.
- Any live event/world flag that changes spawn, reward, map availability or difficulty.

## C — not appropriate for offline simulation

- Siege rewards/pledge carry drops, castle progression and guard battles.
- PVP, troll/player NPC drops and alignment effects.
- Cards, transform chains, combat-only healing/buffs/procs, capture, boss-room respawn/key consumption, Pride/Oblivion/Antharas progression and teleports.

The existing boss/key/hidden-map safety restrictions remain exclusions; they are not relaxed by the catalog.
