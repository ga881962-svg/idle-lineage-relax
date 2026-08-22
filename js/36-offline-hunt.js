/*
 * Server-authoritative offline hunting.
 * The browser never calculates or grants rewards. It only asks idle-api to
 * arm a verified departure and to settle it exactly once after login.
 */
(function () {
    const MIN_ARM_DELAY_MS = 1500;
    const TEXT = {
        title: '\u96e2\u7dda\u639b\u6a5f\u6536\u76ca',
        offline: '\u96e2\u7dda\u6642\u9593',
        active: '\u6709\u6548\u639b\u6a5f\u6642\u9593',
        exp: '\u7372\u5f97\u7d93\u9a57',
        gold: '\u7372\u5f97\u91d1\u5e63',
        items: '\u7372\u5f97\u7269\u54c1',
        none: '\u672a\u7372\u5f97\u7269\u54c1',
        close: '\u95dc\u9589',
        confirm: '\u78ba\u8a8d',
        durationHour: '\u5c0f\u6642',
        durationMinute: '\u5206\u9418',
        settled: '\u96e2\u7dda\u639b\u6a5f\u6536\u76ca\u5df2\u7d50\u7b97\u3002',
        revived: '\u96e2\u7dda\u671f\u9593\u6b7b\u4ea1\u5f8c\u5df2\u81ea\u52d5\u5fa9\u6d3b\u4e26\u5617\u8a66\u8fd4\u56de\u539f\u7df4\u529f\u5730\u5716\u3002',
        blocked: '\u539f\u7df4\u529f\u5730\u5716\u9700\u8981\u7279\u5b9a\u9470\u5319\u6216\u5377\u8ef8\uff0c\u4e0d\u53ef\u81ea\u52d5\u8fd4\u56de\u3002'
    };
    let armTimer = null;
    let lastArmedMap = '';
    let settling = false;
    let deathReturnInFlight = false;

    function currentMapId() {
        return (typeof mapState !== 'undefined' && mapState && mapState.current) ? String(mapState.current) : '';
    }
    function isCombatMap(mapId) {
        if (!mapId || mapId.indexOf('town_') === 0) return false;
        const pool = typeof DB !== 'undefined' && DB.maps && DB.maps[mapId];
        return Array.isArray(pool) && pool.some(function (mobId) {
            const mob = DB.mobs && DB.mobs[mobId];
            return mob && !mob.boss && !mob.siegeEnemy && !mob.trollPlayer && !mob.noOffline;
        });
    }
    function onlineReady() {
        return typeof window.onlineCloudApi === 'function'
            && typeof window.onlineCloudCharacterId === 'function'
            && !!window.onlineCloudCharacterId()
            && typeof window.onlineCloudSessionToken === 'function'
            && !!window.onlineCloudSessionToken();
    }
    function html(value) {
        return String(value == null ? '' : value).replace(/[&<>"']/g, function (char) {
            return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char];
        });
    }
    function itemName(id) {
        return (typeof DB !== 'undefined' && DB.items && DB.items[id] && (DB.items[id].n || DB.items[id].name)) || id;
    }
    function formatDuration(seconds) {
        seconds = Math.max(0, Math.floor(Number(seconds) || 0));
        const hours = Math.floor(seconds / 3600);
        const minutes = Math.floor((seconds % 3600) / 60);
        return hours ? (hours + ' ' + TEXT.durationHour + ' ' + minutes + ' ' + TEXT.durationMinute) : (minutes + ' ' + TEXT.durationMinute);
    }
    async function acknowledgeSettlement(settlementId) {
        if (!settlementId || !onlineReady()) return;
        try {
            await window.onlineCloudApi({
                action: 'offline.ack',
                characterId: window.onlineCloudCharacterId(),
                settlementId: settlementId,
                requestId: typeof window.onlineCloudRequestId === 'function' ? window.onlineCloudRequestId() : ''
            });
        } catch (error) {
            // The reward was already committed by the server.  A later login
            // can safely show the same unacknowledged receipt again.
            console.warn('offline settlement acknowledgement unavailable', error);
        }
    }
    function closeSettlement() {
        const modal = document.getElementById('offline-hunt-settlement-modal');
        if (modal) modal.remove();
    }
    function showSettlement(result) {
        if (!result || !result.settled) return;
        closeSettlement();
        const rewards = result.rewards || {};
        const rows = Object.keys(rewards.items || {}).map(function (id) {
            return '<li><b>' + html(itemName(id)) + '</b> \u00d7' + Number(rewards.items[id] || 0).toLocaleString() + '</li>';
        }).join('') || '<li>' + TEXT.none + '</li>';
        const modal = document.createElement('section');
        modal.id = 'offline-hunt-settlement-modal';
        modal.className = 'offline-hunt-settlement-modal';
        modal.innerHTML = '<div class="offline-hunt-settlement-card" role="dialog" aria-modal="true" aria-label="' + TEXT.title + '">'
            + '<button type="button" class="offline-hunt-settlement-close" aria-label="' + TEXT.close + '">\u00d7</button>'
            + '<h2>' + TEXT.title + '</h2>'
            + '<p>' + TEXT.offline + '\uff1a<b>' + formatDuration(result.offlineSeconds) + '</b></p>'
            + '<p>' + TEXT.active + '\uff1a<b>' + formatDuration(result.effectiveSeconds) + '</b></p>'
            + '<div class="offline-hunt-settlement-rewards"><p>' + TEXT.exp + '\uff1a<b>+' + Number(rewards.exp || 0).toLocaleString() + '</b></p>'
            + '<p>' + TEXT.gold + '\uff1a<b>+' + Number(rewards.gold || 0).toLocaleString() + '</b></p>'
            + '<div><span>' + TEXT.items + '</span><ul>' + rows + '</ul></div></div>'
            + (result.revived ? '<p class="offline-hunt-settlement-note">' + TEXT.revived + '</p>' : '')
            + (result.returnBlocked ? '<p class="offline-hunt-settlement-note is-warning">' + TEXT.blocked + '</p>' : '')
            + '<button type="button" class="offline-hunt-settlement-confirm">' + TEXT.confirm + '</button></div>';
        document.body.appendChild(modal);
        const dismiss = function () {
            closeSettlement();
            acknowledgeSettlement(result.settlementId);
        };
        modal.querySelector('.offline-hunt-settlement-close').onclick = dismiss;
        modal.querySelector('.offline-hunt-settlement-confirm').onclick = dismiss;
    }
    function applyAuthoritativeState(state, revision) {
        if (!state || !state.p || !state.ms || typeof _lzSet !== 'function' || typeof _saveWrap !== 'function') return false;
        const slot = (typeof currentSlot !== 'undefined' && currentSlot) ? currentSlot : 1;
        const saved = _lzSet('lineage_idle_save_' + slot, _saveWrap(JSON.stringify(state)));
        if (!saved) return false;
        if (typeof window.onlineCloudCheckpointRevision === 'function') window.onlineCloudCheckpointRevision(revision);
        if (typeof loadGame === 'function') loadGame();
        return true;
    }
    async function settleOnLogin() {
        if (settling || !onlineReady()) return null;
        settling = true;
        try {
            const result = await window.onlineCloudApi({
                action: 'offline.settle',
                characterId: window.onlineCloudCharacterId(),
                requestId: typeof window.onlineCloudRequestId === 'function' ? window.onlineCloudRequestId() : ''
            });
            if (result && result.state) applyAuthoritativeState(result.state, result.revision);
            // A return to the old hunting map is a one-shot continuation of
            // this server settlement, not a restriction on ordinary manual
            // travel.  The map itself is still verified again by
            // offline.return.check immediately before travel.
            if (result && result.revived && !result.returnBlocked && typeof player !== 'undefined' && player) {
                player._offlineServerReturnPending = true;
            }
            if (result && result.settled) {
                showSettlement(result);
                if (typeof logSys === 'function') logSys('<span class="text-cyan-300">' + TEXT.settled + '</span>');
            }
            return result || null;
        } catch (error) {
            // Transport failures must never fall back to client-side rewards.
            console.warn('offline settlement unavailable', error);
            return null;
        } finally {
            settling = false;
        }
    }
    async function refreshDepartureAfterCheckpoint() {
        if (!onlineReady() || !isCombatMap(currentMapId())) return false;
        const mapId = currentMapId();
        if (typeof window.ensureOnlineSponsorPassStatus === 'function') await window.ensureOnlineSponsorPassStatus();
        const recentRate = typeof window.offlineHuntRecentTenMinuteSnapshot === 'function'
            ? window.offlineHuntRecentTenMinuteSnapshot() : null;
        if (!recentRate) return false;
        try {
            const result = await window.onlineCloudApi({
                action: 'offline.arm',
                characterId: window.onlineCloudCharacterId(),
                mapId: mapId,
                recentRate: recentRate,
                requestId: typeof window.onlineCloudRequestId === 'function' ? window.onlineCloudRequestId() : ''
            });
            if (result && result.armed) lastArmedMap = mapId;
            return !!(result && result.armed);
        } catch (error) {
            if (/SESSION_REPLACED|SESSION_REQUIRED|INVALID_SESSION|SESSION_EXPIRED/i.test(String(error && (error.message || error)))) {
                // The authenticated gateway owns the only session token. Once
                // it says that token is no longer current, stop this departure
                // chain and hand off to the existing Session v19 failure path.
                if (typeof window.onlineCloudHandleSessionFailure === 'function') {
                    await window.onlineCloudHandleSessionFailure(error);
                }
                return false;
            }
            if (/OFFLINE_SNAPSHOT_REJECTED/i.test(String(error && (error.message || error)))) {
                // The server has persisted the anomaly and invalidated this
                // session.  Do not retry the submitted rate or arm locally.
                if (typeof window.onlineAuthSignOut === 'function') await window.onlineAuthSignOut();
                return false;
            }
            console.warn('offline departure was not armed', error);
            return false;
        }
    }
    async function armDeparture() {
        if (!onlineReady() || !isCombatMap(currentMapId())) return false;
        // Persist the current map first.  Every successful cloud checkpoint
        // refreshes the server departure timestamp, so online play time is
        // never counted as offline time.
        if (typeof window.onlineCloudSyncNow === 'function') await window.onlineCloudSyncNow();
        if (lastArmedMap === currentMapId()) return true;
        return refreshDepartureAfterCheckpoint();
    }
    function scheduleArm() {
        if (armTimer) clearTimeout(armTimer);
        armTimer = setTimeout(function () { armTimer = null; armDeparture(); }, MIN_ARM_DELAY_MS);
    }
    async function disarm(reason) {
        if (armTimer) { clearTimeout(armTimer); armTimer = null; }
        lastArmedMap = '';
        if (!onlineReady()) return false;
        try {
            const result = await window.onlineCloudApi({
                action: 'offline.disarm',
                characterId: window.onlineCloudCharacterId(),
                reason: String(reason || 'not_in_combat'),
                requestId: typeof window.onlineCloudRequestId === 'function' ? window.onlineCloudRequestId() : ''
            });
            return !!(result && result.ok);
        } catch (error) {
            console.warn('offline departure disarm unavailable', error);
            return false;
        }
    }
    async function canReturnToLastMap(mapId) {
        if (!onlineReady()) return { allowed: false, reason: 'MAP_UNAVAILABLE' };
        try {
            const result = await window.onlineCloudApi({
                action: 'offline.return.check',
                characterId: window.onlineCloudCharacterId()
            });
            return result && typeof result === 'object' ? result : { allowed: false, reason: 'MAP_UNAVAILABLE' };
        } catch (error) {
            console.warn('offline return validation unavailable', error);
            return { allowed: false, reason: 'MAP_UNAVAILABLE' };
        }
    }

    async function returnToLastMap(context) {
        if (!onlineReady()) return { allowed: false, reason: 'MAP_UNAVAILABLE' };
        const check = await canReturnToLastMap();
        if (!check.allowed || !check.mapId) return check;
        try {
            const result = await window.onlineCloudApi({
                action: context === 'offline_return' ? 'offline.return' : 'map.entry', characterId: window.onlineCloudCharacterId(), mapId: check.mapId,
                context: context || 'death_return',
                revision: typeof window.onlineCloudCheckpointRevision === 'function' ? window.onlineCloudCheckpointRevision() : -1,
                requestId: typeof window.onlineCloudRequestId === 'function' ? window.onlineCloudRequestId() : ''
            });
            if (result && result.state) applyAuthoritativeState(result.state, result.revision);
            return result && typeof result === 'object' ? result : { allowed: false, reason: 'MAP_UNAVAILABLE' };
        } catch (error) {
            const message = String(error && (error.message || error.error || error) || 'MAP_UNAVAILABLE');
            if (/CHECKPOINT_CONFLICT/i.test(message) && typeof window.onlineCloudRestoreCheckpoint === 'function') await window.onlineCloudRestoreCheckpoint();
            return { allowed: false, reason: (message.match(/(CHECKPOINT_CONFLICT|OFFLINE_FEATURE_DISABLED|OFFLINE_PASS_REQUIRED|MISSING_SCROLL|MISSING_KEY|SHIP_REQUIRED|LEVEL_REQUIRED|QUEST_REQUIRED|PASS_REQUIRED|CASTLE_REQUIRED|MAP_UNAVAILABLE|PVP_RETURN_DISABLED)/) || [])[1] || 'MAP_UNAVAILABLE' };
        }
    }

    // This is the one online death continuation.  It deliberately reuses the
    // canonical return check and map-entry RPC; ordinary "Depart" never calls
    // this path and remains independent from the Offline Pass.
    async function deathReturnAfterDefeat() {
        if (!onlineReady()) return { attempted: false, allowed: false, reason: 'OFFLINE_NOT_ONLINE' };
        if (deathReturnInFlight) return { attempted: true, allowed: false, reason: 'RETURN_IN_PROGRESS' };
        deathReturnInFlight = true;
        try {
            const result = await returnToLastMap('death_return');
            return Object.assign({ attempted: true }, result || { allowed: false, reason: 'MAP_UNAVAILABLE' });
        } finally {
            deathReturnInFlight = false;
        }
    }

    /* Legacy per-kill sampling is intentionally disabled: canonical offline
       departures use only the observed rolling ten-minute snapshot. */
    /* function recordKill(mobId, mapId) {
        if (!onlineReady() || !mobId || !mapId || !isCombatMap(mapId)) return false;
        const requestId = typeof window.onlineCloudRequestId === 'function' ? window.onlineCloudRequestId() : '';
        if (!requestId || killReports.has(requestId)) return false;
        killReports.add(requestId);
        window.onlineCloudApi({
            action: 'offline.kill',
            characterId: window.onlineCloudCharacterId(),
            mapId: String(mapId),
            mobId: String(mobId),
            requestId: requestId
        }).catch(function (error) {
            // 擊殺採樣失敗不影響當前線上戰鬥，也絕不退回前端計算收益。
            if (!/KILL_RATE_LIMIT|OFFLINE_PASS_INACTIVE/i.test(String(error && (error.message || error.error) || error))) {
                console.warn('offline combat sample unavailable', error);
            }
        }).finally(function () {
            killReports.delete(requestId);
        });
        return true;
    }

    */
    window.offlineHuntRules = { maxHours: 12, serverAuthoritative: true };
    window.offlineHuntSetDeparture = armDeparture;
    window.offlineHuntResolve = settleOnLogin;
    window.offlineHuntScheduleArm = scheduleArm;
    window.offlineHuntRefreshDeparture = refreshDepartureAfterCheckpoint;
    window.offlineHuntDisarm = disarm;
    window.offlineHuntCanReturn = canReturnToLastMap;
    window.offlineHuntReturnToLastMap = returnToLastMap;
    window.offlineHuntDeathReturnAfterDefeat = deathReturnAfterDefeat;
}());
