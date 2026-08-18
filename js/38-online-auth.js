/* 放置天堂－休閒養老：雲端帳號與角色入口。
   角色清單與建立透過 Edge Function；戰鬥結算尚未切到雲端。 */
(function () {
    'use strict';
    const PROJECT_URL = 'https://fsolkoidqqzwjitbycds.supabase.co';
    const PUBLISHABLE_KEY = 'sb_publishable_6dGqR3k2nC16G46ecxlI5Q_8fJsp5ck';
    // Avoid browser privacy extensions blocking the previous function slug.
    const GAME_API_FUNCTION = 'idle-api';
    let client = null;
    let activeUser = null;
    let cloudGmRole = null;
    const cloudSync = { characterId:null, revision:0, timer:null, retryTimer:null, inFlight:false, warned:false, ready:false, sessionToken:null, sessionUserId:null, heartbeat:null, opening:null, locked:false, kicking:false };
    const DEVICE_STORAGE_KEY = 'idle_lineage_device_id_v1';

    function newUuid() {
        if (window.crypto && typeof window.crypto.randomUUID === 'function') return window.crypto.randomUUID();
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
            var r = Math.random() * 16 | 0, v = c === 'x' ? r : (r & 3 | 8);
            return v.toString(16);
        });
    }
    function deviceId() {
        var id = localStorage.getItem(DEVICE_STORAGE_KEY);
        if (!id || !/^[0-9a-f-]{36}$/i.test(id)) {
            id = newUuid();
            localStorage.setItem(DEVICE_STORAGE_KEY, id);
        }
        return id;
    }
    const CLASS_LABELS = { royal:'王族', prince:'王族', knight:'騎士', elf:'妖精', mage:'法師', wizard:'法師', dark:'黑暗妖精', darkelf:'黑暗妖精', dragon:'龍騎士', dragonknight:'龍騎士', warrior:'戰士', illusion:'幻術士', illusionist:'幻術士' };
    // 伺服器職業代號固定，畫面則沿用現有遊戲的職業名稱。
    const API_CLASS_IDS = { royal:'prince', mage:'wizard', dark:'darkelf', dragon:'dragonknight', illusion:'illusionist' };

    function esc(value) {
        return String(value || '').replace(/[&<>"']/g, function (c) {
            return { '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#039;' }[c];
        });
    }
    function message(text, type) {
        const el = document.getElementById('online-auth-message') || document.getElementById('online-roster-message');
        if (!el) return;
        el.className = 'online-auth-message ' + (type || '');
        el.textContent = text || '';
    }
    // New players use an account name, not an email address. The generated
    // address is an internal Supabase identifier and is never shown in-game.
    const ACCOUNT_EMAIL_DOMAIN = 'players.idle-lineage.local';
    function accountCredentials(value) {
        const raw = String(value || '').trim().toLowerCase();
        if (!raw) return null;
        // Keep legacy email accounts working for existing players/admins.
        if (raw.indexOf('@') !== -1) return { email:raw, account:null, legacy:true };
        if (!/^[a-z0-9_]{3,20}$/.test(raw)) return null;
        return { email:raw + '@' + ACCOUNT_EMAIL_DOMAIN, account:raw, legacy:false };
    }
    function displayAccount(user) {
        if (!user) return '';
        const metadataName = user.user_metadata && user.user_metadata.account_name;
        if (metadataName) return String(metadataName);
        const email = String(user.email || '已登入玩家');
        const suffix = '@' + ACCOUNT_EMAIL_DOMAIN;
        return email.endsWith(suffix) ? email.slice(0, -suffix.length) : email;
    }
    async function gameApi(body) {
        // 部分瀏覽器擴充功能會攔截 Supabase Edge Function 路徑。
        // 角色名單與存檔改走受 RLS / 函式驗證的資料庫 RPC，避免卡在被攔截的請求。
        // 角色建立與存檔一律走 Edge Function。瀏覽器不再直接寫入
        // checkpoint，金幣、物品、離線收益才能由伺服器檢查與留稽核紀錄。
        var payload = Object.assign({}, body || {});
        if (cloudSync.sessionToken && payload.action !== 'session.open') payload.sessionToken = cloudSync.sessionToken;
        let result;
        try {
            result = await client.functions.invoke(GAME_API_FUNCTION, { body:payload });
        } catch (networkError) {
            window.__idleLastApiFailure = {
                action: payload.action,
                status: null,
                message: String(networkError && (networkError.message || networkError) || 'NETWORK_ERROR')
            };
            throw networkError;
        }
        // Supabase wraps non-2xx Edge Function responses in a generic error.
        // Read the response payload as well so session conflicts can be handled
        // as a normal "take over this account" flow instead of looking like a
        // broken cloud save connection.
        if (result.error) {
            // Kept as a read-only diagnostic so a support check can identify
            // whether a failed session open came from the server or transport.
            window.__idleLastApiFailure = {
                action: payload.action,
                status: result.error.context && result.error.context.status || null,
                message: String(result.error.message || result.error)
            };
            try {
                const response = result.error.context;
                // `functions.invoke` exposes the status on the Response even
                // when an intermediary strips its JSON body.
                if (response && response.status === 409) throw new Error('SESSION_REPLACED');
                const body = response && typeof response.clone === 'function'
                    ? await response.clone().json()
                    : null;
                if (body && body.error) throw new Error(String(body.error));
            } catch (detailError) {
                if (/SESSION_REPLACED|SESSION_REQUIRED|INVALID_SESSION|SESSION_LEASE_FAILED|SESSION_OPEN_FAILED/i.test(sessionErrorCode(detailError))) {
                    throw detailError;
                }
            }
            throw result.error;
        }
        if (result.data && result.data.error) throw new Error(result.data.error);
        return result.data || {};
    }
    // Other online-only UI features (for example Broadcast chat) must go
    // through this authenticated gateway.  Do not expose the session token
    // separately to feature scripts.
    window.onlineCloudApi = gameApi;
    function sessionErrorCode(error) {
        return String(error && (error.message || error) || '');
    }
    function isSessionError(error) {
        return /SESSION_REPLACED|SESSION_REQUIRED|INVALID_SESSION|SESSION_EXPIRED/i.test(sessionErrorCode(error));
    }
    function sessionDiagnosticCode(error) {
        var match = sessionErrorCode(error).match(/SESSION_REPLACED|SESSION_REQUIRED|INVALID_SESSION|SESSION_EXPIRED/i);
        return match ? match[0].toUpperCase() : 'UNKNOWN_SESSION_ERROR';
    }
    function removeSessionOverlay() {
        var old = document.getElementById('online-session-lock');
        if (old) old.remove();
    }
    function showSessionOverlay(code) {
        removeSessionOverlay();
        var title = code === 'SESSION_REPLACED' ? '此帳號已在其他裝置登入' : '線上工作階段已中止';
        var detail = code === 'SESSION_REPLACED'
          ? '此帳號的工作階段已被另一個登入取代。'
          : '請重新登入；若持續發生，請提供下方診斷代碼。';
        var overlay = document.createElement('div');
        overlay.id = 'online-session-lock';
        overlay.className = 'online-session-lock';
        overlay.innerHTML = '<section class="online-session-lock-card" role="dialog" aria-modal="true">'
          + '<div class="online-session-lock-icon">🔒</div>'
          + '<h2>' + title + '</h2>'
          + '<p>' + detail + '<br><small>診斷代碼：' + code + '</small></p>'
          + '<button class="online-session-logout" type="button" onclick="window.onlineSessionLogout()">登出／改用其他帳號</button>'
          + '</section>';
        document.body.appendChild(overlay);
    }
    function loginModalMarkup() {
        return '<div class="online-auth-dialog" role="dialog" aria-modal="true" aria-label="線上帳號">'
          + '<button type="button" class="online-auth-close" onclick="onlineAuthClose()">×</button>'
          + '<h2>放置天堂－休閒養老</h2><p>建立帳號後，未來可在網頁與 Windows 安裝版共用角色。</p>'
          + '<label>帳號<input id="online-auth-account" type="text" autocomplete="username" maxlength="20" placeholder="3～20 碼英文小寫、數字或 _"></label>'
          + '<label>密碼<input id="online-auth-password" type="password" minlength="8" autocomplete="current-password" placeholder="至少 8 碼"></label>'
          + '<div class="online-auth-actions"><button type="button" onclick="onlineAuthEmail(false)">登入</button><button type="button" class="secondary" onclick="onlineAuthEmail(true)">註冊</button></div>'
          + '<p class="online-auth-note">新玩家只需帳號與密碼，不使用 Email 驗證。舊玩家仍可用原本 Email 登入。</p>'
          + '<div id="online-auth-message" class="online-auth-message" aria-live="polite"></div>'
          + '</div>';
    }
    function resetToSignedOutShell() {
        // This is deliberately separate from returnToCharacterSelect(): that
        // path saves the current role and keeps the authenticated roster open.
        // A replaced session must never perform either action.
        try { if (typeof clearSessionLogs === 'function') clearSessionLogs(); } catch (_) {}
        cloudSync.characterId = null;
        cloudSync.revision = 0;
        cloudSync.ready = false;
        cloudSync.warned = false;
        try { if (typeof state !== 'undefined' && state) state.running = false; } catch (_) {}
        try { if (typeof player !== 'undefined') player = null; } catch (_) {}
        ['game-screen', 'load-select-panel', 'creation-panel'].forEach(function (id) {
            var element = document.getElementById(id);
            if (element) element.classList.add('hidden');
        });
        var creationScreen = document.getElementById('creation-screen');
        var mainMenu = document.getElementById('main-menu');
        if (creationScreen) creationScreen.classList.remove('hidden');
        if (mainMenu) mainMenu.classList.remove('hidden');
        document.querySelectorAll('[id$="-modal"], [id^="modal-"]').forEach(function (element) {
            if (element.id !== 'online-auth-modal') element.classList.add('hidden');
        });
        document.body.classList.remove('game-bg-dim', 'sherine-world', 'sherine-mad');
        var modal = document.getElementById('online-auth-modal');
        if (modal) {
            modal.innerHTML = loginModalMarkup();
            modal.classList.remove('hidden');
        }
        render(null);
    }
    function stopCloudActivity() {
        cloudSync.locked = true;
        if (cloudSync.timer) { clearTimeout(cloudSync.timer); cloudSync.timer = null; }
        if (cloudSync.retryTimer) { clearTimeout(cloudSync.retryTimer); cloudSync.retryTimer = null; }
        if (cloudSync.heartbeat) { clearInterval(cloudSync.heartbeat); cloudSync.heartbeat = null; }
        // Stop the local combat and save loops before signing out.  An already
        // in-flight request is harmless because the server re-checks its token.
        if (typeof window.stopGameTimers === 'function') window.stopGameTimers();
    }
    async function sessionKicked(error) {
        if (cloudSync.kicking) return;
        cloudSync.kicking = true;
        stopCloudActivity();
        if (typeof window.onlineWorldChatReset === 'function') window.onlineWorldChatReset();
        cloudSync.sessionToken = null;
        cloudSync.sessionUserId = null;
        var code = sessionDiagnosticCode(error);
        window.__idleSessionFailure = code;
        // Use local sign-out only: a global Supabase sign-out would also
        // invalidate the new device's Auth session.
        try { if (client) await client.auth.signOut({ scope:'local' }); } catch (_) {}
        activeUser = null;
        resetToSignedOutShell();
        showSessionOverlay(code);
        message('線上工作階段已中止：' + code, 'error');
        cloudSync.kicking = false;
    }
    async function openGameSession(user) {
        if (!user || !client) {
            window.__idleSessionFailure = 'CLIENT_OR_USER_UNAVAILABLE';
            return false;
        }
        if (cloudSync.sessionUserId === user.id && cloudSync.sessionToken && !cloudSync.locked) return true;
        if (cloudSync.opening) return cloudSync.opening;
        window.__idleSessionOpening = true;
        cloudSync.opening = (async function () {
            window.__idleSessionFailure = null;
            try {
                var data;
                try {
                    data = await gameApi({ action:'session.open', deviceId:deviceId() });
                } catch (firstError) {
                    // A restored browser tab can still have an expired Auth token. Refresh it
                    // once before treating the secure game session as unavailable.
                    var authProblem = /401|JWT|Auth session missing|Invalid JWT/i.test(sessionErrorCode(firstError));
                    if (!authProblem) throw firstError;
                    var refreshed = await client.auth.refreshSession();
                    if (refreshed.error || !refreshed.data || !refreshed.data.user) throw firstError;
                    activeUser = refreshed.data.user;
                    data = await gameApi({ action:'session.open', deviceId:deviceId() });
                }
                if (!data || !data.sessionToken) throw new Error('SESSION_OPEN_FAILED');
                cloudSync.sessionToken = data.sessionToken;
                cloudSync.sessionUserId = user.id;
                cloudSync.locked = false;
                removeSessionOverlay();
                // World chat is an ephemeral Broadcast channel. Connect only
                // after this browser has a server-issued game session token.
                if (typeof window.onlineWorldChatConnect === 'function') window.onlineWorldChatConnect();
                if (cloudSync.heartbeat) clearInterval(cloudSync.heartbeat);
                cloudSync.heartbeat = setInterval(function () {
                    gameApi({ action:'session.heartbeat' }).catch(function (error) {
                        if (isSessionError(error)) sessionKicked(error);
                    });
                }, 10000);
                return true;
            } catch (error) {
                window.__idleSessionFailure = String(error && (error.message || error) || 'SESSION_OPEN_FAILED');
                if (isSessionError(error)) await sessionKicked(error);
                else message('安全連線暫時無法建立，請確認網路後重試。', 'error');
                return false;
            } finally { cloudSync.opening = null; window.__idleSessionOpening = false; }
        })();
        return cloudSync.opening;
    }
    window.onlineSessionLogout = async function () {
        const token = cloudSync.sessionToken;
        stopCloudActivity();
        if (typeof window.onlineWorldChatReset === 'function') window.onlineWorldChatReset();
        // Closing a replaced token cannot affect the new token because the
        // server updates only the matching token row.
        try { if (client && token) await gameApi({ action:'session.close', sessionToken:token }); } catch (_) {}
        try { if (client) await client.auth.signOut({ scope:'local' }); } catch (_) {}
        activeUser = null;
        cloudSync.sessionToken = null;
        cloudSync.sessionUserId = null;
        removeSessionOverlay();
        resetToSignedOutShell();
    };
    function applyCloudGmAccess(allowed) {
        const toggle = document.getElementById('gm-toggle');
        const panel = document.getElementById('gm-panel');
        if (toggle) toggle.style.display = allowed ? '' : 'none';
        if (!allowed && panel) panel.hidden = true;
    }
    async function refreshCloudGmAccess(user) {
        cloudGmRole = null;
        if (!user || !client) return applyCloudGmAccess(false);
        try {
            const data = await gameApi({ action:'gm.status' });
            cloudGmRole = data.allowed ? data.role : null;
            applyCloudGmAccess(!!cloudGmRole);
        } catch (error) {
            applyCloudGmAccess(false);
        }
    }
    function queueCloudSave(delay) {
        if (cloudSync.locked || !cloudSync.sessionToken || !cloudSync.characterId || cloudSync.timer || cloudSync.inFlight) return;
        cloudSync.timer = setTimeout(function () {
            cloudSync.timer = null;
            syncCloudSave();
        }, Number.isFinite(Number(delay)) ? Number(delay) : 15000);
    }
    async function syncCloudSave() {
        if (cloudSync.locked || !cloudSync.sessionToken || !cloudSync.characterId || cloudSync.inFlight || typeof player === 'undefined' || !player || !player.cls || player.cloudCharacterId !== cloudSync.characterId) return;
        if (typeof saveStateJson !== 'function') return;
        cloudSync.inFlight = true;
        try {
            const state = JSON.parse(saveStateJson());
            const data = await gameApi({ action:'checkpoint.write', characterId:cloudSync.characterId, revision:cloudSync.revision, requestId:newUuid(), state:state });
            cloudSync.revision = Number(data.revision || cloudSync.revision);
            // Refresh the server-owned offline departure only after the
            // checkpoint commit succeeds. This prevents normal online play
            // time from being included in the later offline settlement.
            if (typeof window.offlineHuntRefreshDeparture === 'function') {
                await window.offlineHuntRefreshDeparture();
            }
            cloudSync.warned = false;
            if (!cloudSync.ready && typeof logSys === 'function') {
                cloudSync.ready = true;
                if (typeof window.onlineCloudWarehouseBootstrap === 'function') window.onlineCloudWarehouseBootstrap().catch(function () {});
                logSys('<span class="text-cyan-300">☁ 雲端進度同步已啟用。</span>');
            }
        } catch (error) {
            if (isSessionError(error)) { await sessionKicked(error); return; }
            if (/CHECKPOINT_CONFLICT/i.test(String(error && (error.message || error)))) {
                // A server action advanced the revision. Never retry the stale
                // browser snapshot: reload the canonical checkpoint first.
                await restoreCurrentCloudCheckpoint();
                return;
            }
            if (!cloudSync.warned && typeof logSys === 'function') {
                cloudSync.warned = true;
                logSys('<span class="text-yellow-300">☁ 雲端存檔暫時未完成，本機進度仍已保留。</span>');
            }
            // Transient transport failures are retried, but never bypass the
            // server session check or fall back to a direct database write.
            if (!cloudSync.locked && cloudSync.sessionToken && !cloudSync.retryTimer) {
                cloudSync.retryTimer = setTimeout(function () {
                    cloudSync.retryTimer = null;
                    syncCloudSave();
                }, 10000);
            }
        } finally {
            cloudSync.inFlight = false;
        }
    }
    async function restoreCloudSave(characterId, localSlot) {
        var checkpoint = null;
        var apiError = null;
        try {
            const data = await gameApi({ action:'checkpoint.read', characterId:characterId });
            checkpoint = data && data.checkpoint;
        } catch (error) {
            apiError = error;
            if (isSessionError(error)) await sessionKicked(error);
            return null;
            /* Legacy direct database fallback intentionally disabled: the
               active session token must be verified by idle-api first. */
            /*
            // 資料庫讀取權限取得同一份存檔，不能因單一路徑失敗而遺失進度。
            try {
                const direct = await client.from('character_checkpoints')
                    .select('revision,state,saved_at')
                    .eq('character_id', characterId)
                    .maybeSingle();
                if (direct.error) throw direct.error;
                checkpoint = direct.data || null;
            } catch (directError) {
                console.warn('讀取雲端存檔失敗。', apiError, directError);
                return null; // 連線錯誤：絕不能把既有角色當成新角色開局。
            }
            */
        }
        if (!checkpoint) return false; // 新建立、尚未有任何存檔的角色。
        if (!checkpoint.state || typeof checkpoint.state !== 'object') return null;
        if (!checkpoint.state.p || !checkpoint.state.ms || typeof _lzSet !== 'function' || typeof _saveWrap !== 'function') return null;
        if (!_lzSet('lineage_idle_save_' + localSlot, _saveWrap(JSON.stringify(checkpoint.state)))) return null;
        cloudSync.revision = Number(checkpoint.revision || 0);
        return true;
    }
    async function restoreCurrentCloudCheckpoint() {
        if (!cloudSync.sessionToken || !cloudSync.characterId) return false;
        var slot = (typeof currentSlot !== 'undefined') ? currentSlot : 1;
        var restored = await restoreCloudSave(cloudSync.characterId, slot);
        if (!restored) return false;
        // restoreCloudSave writes exactly the server checkpoint to the slot;
        // loadGame then replaces the in-memory character instead of merging it.
        if (typeof loadGame === 'function') loadGame();
        if (typeof player !== 'undefined' && player) {
            player.cloudCharacterId = cloudSync.characterId;
            if (activeUser) player.cloudAccountId = activeUser.id;
        }
        if (typeof updateUI === 'function') updateUI();
        return true;
    }
    function installCloudSaveBridge() {
        if (window.__idleCloudSaveBridge || typeof window.saveGame !== 'function') return;
        window.__idleCloudSaveBridge = true;
        const localSaveGame = window.saveGame;
        window.saveGame = function () {
            const saved = localSaveGame.apply(this, arguments);
            if (saved) queueCloudSave();
            return saved;
        };
        window.addEventListener('visibilitychange', function () {
            if (document.visibilityState === 'hidden') syncCloudSave();
        });
        window.addEventListener('pagehide', function () {
            if (cloudSync.locked) return;
            // The offline-hunt arm call performs its own verified checkpoint
            // sync before asking the server to record the departure.  Do not
            // send a competing final browser save here.
            if (typeof window.offlineHuntSetDeparture === 'function') window.offlineHuntSetDeparture();
            else syncCloudSave();
        });
        // 網路短暫中斷或筆電休眠後，恢復連線時自動補送本機已保存的進度。
        window.addEventListener('online', function () { syncCloudSave(); });
        setInterval(function () {
            if (document.visibilityState === 'visible') syncCloudSave();
        }, 45000);
    }
    function render(user) {
        activeUser = user || null;
        const root = document.getElementById('online-auth-root');
        if (!root) return;
        const label = user ? displayAccount(user) : '尚未登入';
        root.innerHTML = '<section class="online-auth-card">'
          + '<div class="online-auth-title">☁ 線上帳號</div>'
          + '<div class="online-auth-user">' + esc(label) + '</div>'
          + (user
            ? '<div class="online-auth-card-actions"><button type="button" class="online-auth-button" onclick="onlineRosterOpen()">我的存檔</button><button type="button" class="online-auth-button subtle" onclick="onlineAuthSignOut()">登出</button></div>'
            : '<button type="button" class="online-auth-button" onclick="onlineAuthOpen()">註冊／登入</button>')
          + '<div class="online-auth-note">'+ (user ? '可建立最多 8 個角色存檔；請從「我的存檔」選擇角色。' : '建立帳號或登入後，即可選擇你的存檔。') +'</div>'
          + '</section>';
        if (user) {
            openGameSession(user).then(function (ok) { refreshCloudGmAccess(ok ? user : null); });
        } else {
            refreshCloudGmAccess(null);
        }
    }
    function showModal() {
        let modal = document.getElementById('online-auth-modal');
        if (!modal) return;
        modal.classList.remove('hidden');
        message('');
    }
    function hideModal() {
        const modal = document.getElementById('online-auth-modal');
        if (modal) modal.classList.add('hidden');
    }
    async function emailAuth(isSignUp) {
        if (!client) return message('線上帳號服務尚未準備完成，請重新整理。', 'error');
        const accountInput = (document.getElementById('online-auth-account').value || '').trim();
        const password = document.getElementById('online-auth-password').value || '';
        const credentials = accountCredentials(accountInput);
        if (!credentials || password.length < 8) return message('請輸入 3～20 碼帳號（英文小寫、數字或 _）與至少 8 碼密碼。舊玩家也可用 Email 登入。', 'error');
        if (isSignUp && credentials.legacy) return message('新註冊請設定帳號，不需要填 Email。', 'error');
        message('處理中…');
        let result;
        if (isSignUp) {
            result = await client.auth.signUp({
                email: credentials.email,
                password: password,
                options: { data: { account_name:credentials.account } }
            });
        } else {
            result = await client.auth.signInWithPassword({ email: credentials.email, password: password });
        }
        if (result.error) return message(result.error.message, 'error');
        if (isSignUp && !result.data.session) {
            message('帳號已建立，但雲端仍開啟 Email 驗證；請由管理員關閉「Confirm email」後即可直接登入。', 'error');
        } else {
            message(isSignUp ? '帳號建立成功，已直接登入。' : '登入成功。', 'success');
            setTimeout(hideModal, 500);
        }
    }
    async function googleAuth() {
        if (!client) return message('線上帳號服務尚未準備完成，請重新整理。', 'error');
        message('正在轉往 Google…');
        // Keep OAuth on the current page so a GitHub Pages project subpath is preserved.
        const result = await client.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: window.location.origin + window.location.pathname } });
        if (result.error) message(result.error.message, 'error');
    }
    function checkpointLevel(state) {
        // 雲端存檔與本機存檔共用 saveStateJson() 的結構：{ p: player, ... }。
        // 舊檔曾有 p.d 的包裝，因此一併相容，讀不到才使用建角資料表的初始等級。
        const candidates = [
            state && state.p && state.p.lv,
            state && state.p && state.p.level,
            state && state.p && state.p.d && state.p.d.lv,
            state && state.p && state.p.d && state.p.d.level,
            state && state.player && state.player.lv,
            state && state.player && state.player.level
        ];
        for (let i = 0; i < candidates.length; i++) {
            const value = Math.floor(Number(candidates[i]));
            if (Number.isFinite(value) && value > 0) return value;
        }
        return null;
    }
    async function withCheckpointLevels(rows) {
        // Character list data must only come from the session-protected API.
        // The game already keeps the saved level in the checkpoint state after loading.
        return rows || [];
        /*
        if (!client || !Array.isArray(rows) || !rows.length) return rows || [];
        const ids = rows.map(function (row) { return row.id; }).filter(Boolean);
        if (!ids.length) return rows;
        try {
            const result = await client.from('character_checkpoints')
                .select('character_id,state')
                .in('character_id', ids);
            if (result.error || !Array.isArray(result.data)) return rows;
            const levels = {};
            result.data.forEach(function (checkpoint) {
                const level = checkpointLevel(checkpoint && checkpoint.state);
                if (checkpoint && checkpoint.character_id && level) levels[checkpoint.character_id] = level;
            });
            return rows.map(function (row) {
                const savedLevel = levels[row.id];
                return savedLevel ? Object.assign({}, row, { level:savedLevel }) : row;
            });
        } catch (error) {
            // 清單不能因單一存檔讀取失敗而無法開啟；保留建角資料中的等級作為備援。
            return rows;
        }
    }
        */
    }
    async function getRoster() {
        if (!client || !activeUser) throw new Error('請先登入帳號。');
        if (!await openGameSession(activeUser)) throw new Error('安全連線尚未建立。');
        try {
            const result = await gameApi({ action:'characters.list' });
            return withCheckpointLevels(Array.isArray(result.characters) ? result.characters : []);
        } catch (apiError) {
            // 角色 RPC 僅能操作登入者自己的角色，作為部署中的安全備援。
            console.warn('game-api 尚未可用，改用受限角色入口。', apiError);
            throw apiError;
        }
    }
    function rosterClassOptions() {
        return Object.keys(CLASS_LABELS).map(function (id) { return '<option value="' + id + '">' + CLASS_LABELS[id] + '</option>'; }).join('');
    }
    function rosterRows(rows) {
        const bySlot = {};
        rows.forEach(function (r) { bySlot[String(r.slot)] = r; });
        let out = '';
        for (let slot = 1; slot <= 8; slot++) {
            const row = bySlot[String(slot)];
            out += '<div class="online-roster-row ' + (row ? 'filled' : 'empty') + '"><span>欄位 ' + slot + '</span>'
              + (row ? '<strong>' + esc(row.name) + '</strong><em>' + esc(CLASS_LABELS[row.class_id] || row.class_id) + '　Lv.' + Number(row.level || 1) + '</em><button type="button" class="online-roster-enter" onclick="onlineRosterEnter(\'' + esc(row.id) + '\')">進入遊戲</button>' : '<em>尚未建立</em>')
              + '</div>';
        }
        return out;
    }
    function gameClassId(classId) {
        return ({ prince:'royal', wizard:'mage', darkelf:'dark', dragonknight:'dragon', illusionist:'illusion' })[classId] || classId;
    }
    function cloudLocalSlot(row) {
        // 本機暫存位只用於本次遊玩；以帳號雜湊隔離，避免同一台電腦不同帳號互相讀到進度。
        const seed = String(activeUser && activeUser.id || 'guest');
        let hash = 0;
        for (let i = 0; i < seed.length; i++) hash = ((hash * 31) + seed.charCodeAt(i)) >>> 0;
        return 1000000 + (hash % 800000) * 10 + Number(row.slot || 1);
    }
    async function enterCloudCharacter(characterId) {
        try {
            const rows = await getRoster();
            const row = rows.find(function (item) { return item.id === characterId; });
            if (!row) return message('找不到這個存檔，請重新開啟存檔清單。', 'error');
            const cls = gameClassId(row.class_id);
            const rawByClass = { royal:'m_royal', knight:'m_knight', elf:'m_elf', mage:'m_mage', dark:'m_dark', dragon:'m_Dknight', warrior:'m_warrior', illusion:'m_illusionist' };
            const rawCls = rawByClass[cls];
            if (!rawCls || typeof startGame !== 'function' || typeof loadGame !== 'function') throw new Error('遊戲尚未載入完成，請重新整理後再試。');

            // Selecting a character starts a fresh character game session.
            // This is intentionally not in openGameSession(): same-device
            // session reuse/Auth restore must retain the current log.
            try { if (typeof clearSessionLogs === 'function') clearSessionLogs(); } catch (_) {}
            currentSlot = cloudLocalSlot(row);
            cloudSync.characterId = row.id;
            cloudSync.revision = 0;
            hideModal();
            const restoredCloud = await restoreCloudSave(row.id, currentSlot);
            if (restoredCloud === null) {
                throw new Error('雲端存檔暫時讀取失敗。請確認網路後重試，系統不會覆蓋你的既有進度。');
            }
            if (restoredCloud || (typeof slotSummary === 'function' && slotSummary(currentSlot))) {
                loadGame();
                if (typeof player !== 'undefined' && player) {
                    player.cloudCharacterId = row.id;
                    player.cloudAccountId = activeUser.id;
                }
                // Server settlement is intentionally after loadGame: it can
                // replace the local checkpoint with one authoritative result.
                if (typeof window.offlineHuntResolve === 'function') await window.offlineHuntResolve();
                return;
            }
            curCreate.rawCls = rawCls;
            curCreate.cls = cls;
            curCreate.str = 0; curCreate.dex = 0; curCreate.con = 0;
            curCreate.int = 0; curCreate.wis = 0; curCreate.cha = 0;
            startGame();
            if (typeof player !== 'undefined' && player) {
                player.name = row.name;
                player.cloudCharacterId = row.id;
                player.cloudAccountId = activeUser.id;
                if (typeof saveGame === 'function') saveGame();
            }
            if (typeof window.offlineHuntResolve === 'function') await window.offlineHuntResolve();
        } catch (error) {
            message('進入遊戲失敗：' + (error.message || '請重新整理後再試。'), 'error');
        }
    }
    async function showRoster() {
        if (!activeUser) return showModal();
        const modal = document.getElementById('online-auth-modal');
        if (!modal) return;
        modal.classList.remove('hidden');
        modal.innerHTML = '<div class="online-auth-dialog online-roster-dialog"><button type="button" class="online-auth-close" onclick="onlineAuthClose()">×</button><h2>我的存檔</h2><p>此帳號最多可建立 8 名角色。每個角色各自保存遊戲進度，並由伺服器驗證。</p><div id="online-roster-list" class="online-roster-list">讀取中…</div><section class="online-roster-create"><h3>建立新角色</h3><label>角色欄位<select id="online-roster-slot"><option value="1">欄位 1</option><option value="2">欄位 2</option><option value="3">欄位 3</option><option value="4">欄位 4</option><option value="5">欄位 5</option><option value="6">欄位 6</option><option value="7">欄位 7</option><option value="8">欄位 8</option></select></label><label>角色名稱<input id="online-roster-name" maxlength="20" placeholder="1 至 20 個字"></label><label>職業<select id="online-roster-class">' + rosterClassOptions() + '</select></label><button type="button" class="online-roster-create-button" onclick="onlineRosterCreate()">建立角色存檔</button><div id="online-roster-message" class="online-auth-message" aria-live="polite"></div></section></div>';
        try {
            const rows = await getRoster();
            const list = document.getElementById('online-roster-list');
            if (list) list.innerHTML = rosterRows(rows);
        } catch (e) { message('讀取存檔失敗：' + (e.message || '請稍後再試。'), 'error'); }
    }
    async function createRosterCharacter() {
        const slot = Number(document.getElementById('online-roster-slot').value || 0);
        const name = (document.getElementById('online-roster-name').value || '').trim();
        const classId = document.getElementById('online-roster-class').value || '';
        if (!name || name.length > 20) return message('請輸入 1 至 20 個字的角色名稱。', 'error');
        message('建立中…');
        try {
            const result = await gameApi({ action:'characters.create', slot:slot, name:name, classId:(API_CLASS_IDS[classId] || classId) });
            if (result.error) return message(result.error, 'error');
            message('角色存檔已建立。', 'success');
            const rows = await getRoster();
            const list = document.getElementById('online-roster-list');
            if (list) list.innerHTML = rosterRows(rows);
        } catch (e) { message('建立失敗：' + (e.message || '請稍後再試。'), 'error'); }
    }
    window.onlineAuthOpen = showModal;
    window.onlineAuthClose = hideModal;
    window.onlineAuthEmail = emailAuth;
    window.onlineAuthGoogle = googleAuth;
    window.onlineRosterOpen = showRoster;
    window.onlineRosterCreate = createRosterCharacter;
    window.onlineRosterEnter = enterCloudCharacter;
    window.onlineCloudGmGrantDiamonds = async function (amount) {
        if (!cloudGmRole) throw new Error('目前帳號沒有雲端 GM 權限。');
        if (typeof player === 'undefined' || !player || !player.cloudCharacterId) throw new Error('請先進入角色存檔。');
        const data = await gameApi({ action:'gm.wallet.grant', characterId:player.cloudCharacterId, amount:amount });
        const balance = Math.max(0, Math.floor(Number(data.balance) || 0));
        if (typeof window.setOnlineSponsorWalletBalance === 'function') window.setOnlineSponsorWalletBalance(balance);
        player.sponsorDiamonds = balance;
        if (typeof saveGame === 'function') saveGame();
        if (typeof updateUI === 'function') updateUI();
        return balance;
    };
    // 線上 GM 專用：指定玩家帳號發放，不依賴目前 GM 自己正在使用的角色。
    window.onlineCloudGmGrantPlayerDiamonds = async function (targetAccount, amount) {
        if (!cloudGmRole) throw new Error('目前帳號沒有雲端 GM 權限。');
        const data = await gameApi({ action:'gm.player.wallet.grant', targetAccount:targetAccount, amount:amount });
        return data;
    };
    window.onlineCloudGmGrantPlayerItem = async function (targetAccount, targetCharacterName, item) {
        if (!cloudGmRole) throw new Error('目前帳號沒有雲端 GM 權限。');
        return await gameApi({ action:'gm.player.inventory.grant', targetAccount:targetAccount, targetCharacterName:targetCharacterName, item:item });
    };
    // 其他 GM 動作也先同步目前角色，再交由伺服器驗證 GM 身分、更新雲端存檔並留下稽核紀錄。
    window.onlineCloudGmMutate = async function (action, payload) {
        if (!cloudGmRole) throw new Error('目前帳號沒有雲端 GM 權限。');
        if (typeof player === 'undefined' || !player || !player.cloudCharacterId) throw new Error('請先進入角色存檔。');
        let data;
        try {
            data = await gameApi(Object.assign({ action:action, characterId:player.cloudCharacterId }, payload || {}));
        } catch (error) {
            if (/CHECKPOINT_CONFLICT/i.test(String(error && (error.message || error)))) await restoreCurrentCloudCheckpoint();
            throw error;
        }
        if (data && data.state && data.state.p && typeof data.state.p === 'object') Object.assign(player, data.state.p);
        if (Number.isFinite(Number(data.revision))) cloudSync.revision = Number(data.revision);
        return data;
    };
    window.onlineCloudGmAllowed = function () { return !!cloudGmRole; };
    window.onlineAuthSignOut = async function () {
        stopCloudActivity();
        if (typeof window.onlineWorldChatReset === 'function') window.onlineWorldChatReset();
        if (client) await client.auth.signOut();
        activeUser = null;
        cloudSync.sessionToken = null;
        cloudSync.sessionUserId = null;
        resetToSignedOutShell();
    };
    window.onlineSupabase = function () { return client; };
    // Server-side marketplace actions advance the checkpoint revision too.
    // Let those actions hand the latest revision back to the normal saver.
    window.onlineCloudCheckpointRevision = function (revision) {
        if (arguments.length === 0) return cloudSync.revision;
        revision = Number(revision);
        if (Number.isFinite(revision) && revision >= 0) cloudSync.revision = revision;
    };
    window.onlineCloudSessionToken = function () { return cloudSync.sessionToken || ''; };
    window.onlineCloudCharacterId = function () { return cloudSync.characterId || ''; };
    window.onlineCloudRenameCharacter = async function (name) {
        if (!cloudSync.ready || !cloudSync.sessionToken || !cloudSync.characterId) throw new Error('ONLINE_SESSION_REQUIRED');
        const result = await gameApi({ action:'character.rename', characterId:cloudSync.characterId, name:name, requestId:newUuid() });
        if (typeof player !== 'undefined' && player && result && result.name) player.name = String(result.name);
        if (Number.isFinite(Number(result && result.revision))) cloudSync.revision = Number(result.revision);
        if (result && typeof window.setOnlineSponsorWalletBalance === 'function') window.setOnlineSponsorWalletBalance(result.sponsorDiamonds);
        if (typeof saveGame === 'function') saveGame();
        if (typeof updateUI === 'function') updateUI();
        return result;
    };
    window.onlineCloudLeaderboard = async function () {
        if (!cloudSync.ready || !cloudSync.sessionToken || !cloudSync.characterId) throw new Error('ONLINE_SESSION_REQUIRED');
        return await gameApi({ action:'leaderboard.online', characterId:cloudSync.characterId });
    };
    window.onlineAuthIsSignedIn = function () { return !!activeUser; };
    window.onlineCloudAllySnapshots = async function () {
        if (!cloudSync.sessionToken || !cloudSync.characterId) throw new Error('ONLINE_SESSION_REQUIRED');
        const data = await gameApi({ action:'characters.allies', characterId:cloudSync.characterId });
        return Array.isArray(data && data.characters) ? data.characters : [];
    };
    window.onlineMercenaryGuildPassStatus = async function () {
        if (!cloudSync.sessionToken || !cloudSync.characterId) throw new Error('ONLINE_SESSION_REQUIRED');
        return await gameApi({ action:'mercenary.guild.status', characterId:cloudSync.characterId });
    };
    window.onlineMercenaryGuildPassPurchase = async function () {
        if (!cloudSync.sessionToken || !cloudSync.characterId) throw new Error('ONLINE_SESSION_REQUIRED');
        return await gameApi({ action:'mercenary.guild.purchase', characterId:cloudSync.characterId, requestId:newUuid() });
    };
    window.onlineMercenaryGuildAuthorize = async function () {
        if (!cloudSync.sessionToken || !cloudSync.characterId) throw new Error('ONLINE_SESSION_REQUIRED');
        return await gameApi({ action:'mercenary.guild.authorize', characterId:cloudSync.characterId });
    };
    window.onlineCloudSyncNow = syncCloudSave;
    window.onlineCloudRestoreCheckpoint = restoreCurrentCloudCheckpoint;
    window.onlineCloudRequestId = newUuid;
    // Warehouse transfers must advance the in-memory checkpoint immediately.
    // The next ordinary cloud save then carries the server revision instead of
    // replaying the pre-transfer inventory snapshot.
    window.onlineCloudWarehouseActive = function () { return !!window.__serverWarehouseAuthoritative; };
    window.onlineCloudWarehouseTransfer = async function (payload) {
        if (!cloudSync.ready || !cloudSync.sessionToken || !cloudSync.characterId) throw new Error('ONLINE_SESSION_REQUIRED');
        if (!window.onlineCloudWarehouseActive()) throw new Error('WAREHOUSE_NOT_AUTHORITATIVE');
        payload = Object.assign({ action:'warehouse.transfer', characterId:cloudSync.characterId, revision:cloudSync.revision, requestId:newUuid() }, payload || {});
        let result;
        try { result = await gameApi(payload); }
        catch (error) {
            if (/CHECKPOINT_CONFLICT/i.test(String(error && (error.message || error)))) await restoreCurrentCloudCheckpoint();
            throw error;
        }
        if (result && result.state && result.state.p && typeof player !== 'undefined' && player) {
            Object.keys(player).forEach(function (key) { delete player[key]; });
            Object.assign(player, result.state.p);
        }
        if (result && Number.isFinite(Number(result.revision))) cloudSync.revision = Number(result.revision);
        return result;
    };
    window.onlineCloudWarehouseStatus = async function () {
        if (!cloudSync.ready || !cloudSync.sessionToken || !cloudSync.characterId) throw new Error('ONLINE_SESSION_REQUIRED');
        return gameApi({ action:'warehouse.status', characterId:cloudSync.characterId });
    };
    window.onlineCloudWarehouseBootstrap = async function () {
        if (!cloudSync.ready || !cloudSync.sessionToken || !cloudSync.characterId || window.__serverWarehouseBootstrapping) return window.__serverWarehouse || null;
        window.__serverWarehouseBootstrapping = true;
        try {
            let status;
            try { status = await window.onlineCloudWarehouseStatus(); }
            catch (error) {
                if (/FEATURE_DISABLED/i.test(String(error && (error.message || error)))) return null;
                throw error;
            }
            if (status && status.migrationRequired) {
                const legacy = typeof loadWarehouse === 'function' ? loadWarehouse() : { gold:0, items:[] };
                status = await gameApi({ action:'warehouse.migrate', characterId:cloudSync.characterId, requestId:newUuid(), legacyWarehouse:{ gold:Number(legacy.gold) || 0, items:Array.isArray(legacy.items) ? legacy.items : [] } });
            }
            if (status && status.authoritative) {
                window.__serverWarehouse = status;
                window.__serverWarehouseAuthoritative = true;
                try { renderWarehouseNPC(document.getElementById('interaction-content')); } catch (_) {}
            }
            return status || null;
        } finally { window.__serverWarehouseBootstrapping = false; }
    };

    function install() {
        const factory = window.supabase && window.supabase.createClient;
        if (!factory) return setTimeout(install, 80);
        client = factory(PROJECT_URL, PUBLISHABLE_KEY, { auth: { persistSession:true, autoRefreshToken:true, detectSessionInUrl:true } });
        installCloudSaveBridge();
        let root = document.getElementById('online-auth-root');
        if (!root) { root = document.createElement('div'); root.id = 'online-auth-root'; document.body.appendChild(root); }
        const modal = document.createElement('div');
        modal.id = 'online-auth-modal'; modal.className = 'online-auth-modal hidden';
        modal.innerHTML = loginModalMarkup();
        document.body.appendChild(modal);
        // 公開網址首次開啟時，getUser() 可能因網路或瀏覽器隱私設定延遲。
        // 先畫出登入入口，避免首頁空白到使用者以為不能開始遊戲。
        render(null);
        client.auth.getUser().then(function (result) { render(result.data && result.data.user); }).catch(function () { render(null); });
        client.auth.onAuthStateChange(function (_event, session) { render(session && session.user); });
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install); else install();
})();
