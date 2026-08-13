/* Offline hunting: fixed map baseline, never current combat performance. */
(function () {
    const MAX_OFFLINE_MS = 12 * 60 * 60 * 1000;
    const KILLS_PER_MINUTE = 6;
    const MIN_VALID_MS = 60 * 1000;
    const AUTO_REVIVE_DELAY_MS = 30 * 1000;
    let processed = false;
    let originalSave = null;

    function normalMobs(mapId) {
        const pool = typeof DB !== 'undefined' && DB.maps && DB.maps[mapId];
        if (!Array.isArray(pool)) return [];
        return pool.map((id) => DB.mobs[id]).filter((mob) =>
            mob && !mob.boss && !mob.siegeEnemy && !mob.trollPlayer && !mob.noOffline
        );
    }
    function passUntil() {
        return Number(typeof player !== 'undefined' && player.sponsorPasses && player.sponsorPasses.offline) || 0;
    }
    function hasActivePass() { return passUntil() > Date.now(); }
    function eligibleMap(mapId) { return normalMobs(mapId).length > 0; }
    function entryCostForMap(mapId) {
        let id = '';
        if (typeof KING_ROOMS !== 'undefined' && KING_ROOMS && KING_ROOMS[mapId]) id = KING_ROOMS[mapId].key || 'item_king_key';
        if (!id && typeof SANCT_RESPAWN_COST !== 'undefined' && SANCT_RESPAWN_COST && SANCT_RESPAWN_COST[mapId]) id = SANCT_RESPAWN_COST[mapId];
        // These maps charge entry in sanctuaryEnter rather than the combat map table.
        if (!id) id = ({
            dark_elf_sanctuary: 'item_dk_book',
            cursed_dark_elf_sanctuary: 'item_dk_book',
            collapsed_elder_council_hall: 'item_giltas_seal'
        })[mapId] || '';
        return id;
    }
    function entryCostName(itemId) {
        return (typeof DB !== 'undefined' && DB.items && DB.items[itemId] && DB.items[itemId].n) || '入場道具';
    }
    // Only maps clearly above the character level produce simulated offline deaths.
    function deathPlan(job, mobs, usable) {
        const avgLevel = mobs.reduce((sum, mob) => sum + (Number(mob.lv) || 1), 0) / Math.max(1, mobs.length);
        const playerLevel = Math.max(1, Number(player && player.lv) || 1);
        const hardCount = mobs.filter((mob) => mob && mob.hard).length;
        const danger = Math.max(0, avgLevel - playerLevel) + (hardCount / Math.max(1, mobs.length)) * 4;
        const intervalMs = danger > 4 ? Math.max(30 * 60000, Math.floor(240 * 60000 / danger)) : Infinity;
        const requested = Math.max(0, Math.floor(Number(job.deathEvents) || 0));
        const estimated = Number.isFinite(intervalMs) ? Math.floor(usable / intervalMs) : 0;
        const deaths = Math.min(12, requested || estimated);
        return { deaths, firstDeathAtMs: Number.isFinite(intervalMs) ? Math.min(usable, intervalMs) : 0 };
    }
    function seedOf(value) {
        let hash = 2166136261;
        for (const ch of String(value)) { hash ^= ch.charCodeAt(0); hash = Math.imul(hash, 16777619); }
        return hash >>> 0;
    }
    function random(state) {
        state.value = (Math.imul(state.value, 1664525) + 1013904223) >>> 0;
        return state.value / 4294967296;
    }
    function goldFor(mob, roll) {
        if (!mob || mob.noGold) return 0;
        let min = Math.max(0, Number(mob.goldMin) || 0);
        let max = Math.max(min, Number(mob.goldMax) || min);
        if (!max && typeof monsterGoldRange === 'function') {
            const range = monsterGoldRange(mob) || {};
            min = Math.max(0, Number(range.min) || 0);
            max = Math.max(min, Number(range.max) || min);
        }
        return min + Math.floor(roll * (max - min + 1));
    }
    function multiplier(kind) {
        return typeof sponsorGetMultiplier === 'function' ? Math.max(1, Number(sponsorGetMultiplier(kind)) || 1) : 1;
    }
    function dropMultiplier() {
        return typeof sponsorDropMultiplier === 'function' ? Math.max(1, Number(sponsorDropMultiplier()) || 1) : 1;
    }
    function stampDeparture() {
        if (typeof player === 'undefined' || typeof mapState === 'undefined' || !hasActivePass()) return;
        const mapId = mapState.current;
        if (!eligibleMap(mapId)) return;
        const now = Date.now();
        player.offlineHuntV2 = {
            // The cloud API replaces this client time with serverArmedAt.
            ticket: 'oh_' + now.toString(36) + '_' + Math.random().toString(36).slice(2, 10),
            at: now,
            mapId,
            passUntil: passUntil(),
            expMult: Math.min(1.2, multiplier('exp')),
            goldMult: Math.min(1.2, multiplier('gold')),
            dropMult: Math.min(1.2, dropMultiplier()),
            entryCostId: entryCostForMap(mapId),
            maxMinutes: MAX_OFFLINE_MS / 60000,
            version: 2
        };
        player.offlineClockGuard = Math.max(Number(player.offlineClockGuard) || 0, now);
    }
    function resolveRewards() {
        if (processed || typeof player === 'undefined' || !player.offlineHuntV2 || typeof DB === 'undefined') return;
        const job = player.offlineHuntV2;
        const now = Date.now();
        if (now < (Number(player.offlineClockGuard) || 0) || !eligibleMap(job.mapId) || !(Number(job.passUntil) > Number(job.at))) {
            delete player.offlineHuntV2;
            processed = true;
            return;
        }
        // Cloud characters use the server-issued departure time; local-only
        // saves retain the original timestamp for offline play.
        const startedAt = Math.max(0, Number(job.serverArmedAt) || Number(job.at));
        const usable = Math.min(now - startedAt, MAX_OFFLINE_MS, Number(job.passUntil) - startedAt);
        if (!Number.isFinite(usable) || usable < MIN_VALID_MS) return;

        const mobs = normalMobs(job.mapId);
        const costId = entryCostForMap(job.mapId) || job.entryCostId || '';
        const deaths = deathPlan(job, mobs, usable);
        // Entry-key / scroll / seal maps never receive a free return after death.
        const blockedByEntry = !!costId && deaths.deaths > 0;
        const rewardable = blockedByEntry ? Math.max(0, deaths.firstDeathAtMs) :
            Math.max(0, usable - deaths.deaths * AUTO_REVIVE_DELAY_MS);
        const kills = Math.max(0, Math.floor((rewardable / 60000) * KILLS_PER_MINUTE));
        const state = { value: seedOf([job.at, job.mapId, player.enSeed || player.name || '', kills].join('|')) };
        const expMult = Math.max(1, Number(job.expMult) || 1);
        const goldMult = Math.max(1, Number(job.goldMult) || 1);
        const dropMult = Math.max(1, Number(job.dropMult) || 1);
        let exp = 0;
        let gold = 0;
        const items = {};

        for (let i = 0; i < kills; i += 1) {
            const mob = mobs[Math.floor(random(state) * mobs.length)];
            exp += Math.floor((Number(mob.exp) || 0) * expMult);
            gold += Math.floor(goldFor(mob, random(state)) * goldMult);
            const drops = (window.MOB_DROPS && MOB_DROPS[mob.n]) || [];
            drops.forEach((entry) => {
                const itemId = entry && entry[0];
                const chance = Number(entry && entry[1]) || 0;
                if (!itemId || !DB.items[itemId] || chance <= 0) return;
                if (random(state) < Math.min(1, (chance / 100) * dropMult)) items[itemId] = (items[itemId] || 0) + 1;
            });
        }

        player.exp = (Number(player.exp) || 0) + exp;
        player.gold = (Number(player.gold) || 0) + gold;
        if (typeof checkLvUp === 'function') checkLvUp();
        Object.keys(items).forEach((id) => { if (typeof gainItem === 'function') gainItem(id, items[id]); });
        if (blockedByEntry) {
            player.hp = 0;
            player.dead = true;
        } else if (deaths.deaths > 0) {
            // mapState keeps the saved training map, so this is an actual return to its original point.
            player.dead = false;
            player.hp = Math.max(1, Number(player.mhp) || Number(player.hp) || 1);
            player.mp = Math.max(0, Number(player.mmp) || Number(player.mp) || 0);
        }
        const text = Object.keys(items).slice(0, 8).map((id) => `${DB.items[id].n || id} x${items[id]}`).join(', ');
        if (typeof logSys === 'function') {
            const label = '\\u96e2\\u7dda\\u639b\\u6a5f';
            const minutes = '\\u5206\\u9418';
            const defeated = '\\u64ca\\u6557';
            const experience = '\\u7d93\\u9a57';
            const currency = '\\u91d1\\u5e63';
            const dropsLabel = '\\u6389\\u843d';
            logSys(`${label}\uff1a${Math.floor(rewardable / 60000)} ${minutes}\uff0c${kills.toLocaleString()} ${defeated}\uff1b${experience} +${exp.toLocaleString()}\u3001${currency} +${gold.toLocaleString()}${text ? `\uff0c${dropsLabel}\uff1a${text}` : ''}`);
            if (blockedByEntry) {
                logSys(`離線死亡後無法回到原練功點：此地圖需要「${entryCostName(costId)}」入場，系統已停止離線收益。`);
            } else if (deaths.deaths > 0) {
                logSys(`離線死亡 ${deaths.deaths} 次，已自動復活並回到原練功點繼續掛機（每次復活等待 30 秒不計收益）。`);
            }
        }
        delete player.offlineHuntV2;
        player.offlineClockGuard = Math.max(Number(player.offlineClockGuard) || 0, now);
        processed = true;
        if (typeof updateUI === 'function') updateUI();
        if (typeof saveGame === 'function') saveGame();
    }
    function install() {
        if (typeof window.saveGame === 'function' && !originalSave) {
            originalSave = window.saveGame;
            window.saveGame = function () { stampDeparture(); return originalSave.apply(this, arguments); };
        }
        resolveRewards();
    }
    window.offlineHuntRules = { maxHours: 12, killsPerMinute: KILLS_PER_MINUTE, autoReviveDelaySeconds: 30 };
    window.offlineHuntSetDeparture = stampDeparture;
    window.offlineHuntResolve = resolveRewards;
    install();
    setInterval(install, 1000);
    window.addEventListener('pagehide', () => { stampDeparture(); if (originalSave) originalSave(); });
    window.addEventListener('beforeunload', () => { stampDeparture(); if (originalSave) originalSave(); });
}());
