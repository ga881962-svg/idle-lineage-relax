/*
 * 單機 GM 控制台
 * 這個檔案刻意獨立於遊戲本體，方便更新原始遊戲檔後保留管理功能。
 * 開啟方式：右下角 GM 按鈕，或 F10。
 */
(function () {
    'use strict';

    const MAX_LEVEL = 75;
    const statKeys = ['str', 'dex', 'con', 'int', 'wis', 'cha'];
    let gmItemCodePromise = null;

    // 道具編號採用資料表 js/00-data.js 中的行號：例如第 479 行的「真．冥皇執行劍」可直接輸入 479。
    // 用讀取資料表的方式建立索引，新增道具後不用再手動維護第二份對照表。
    function loadItemCodeMap() {
        if (gmItemCodePromise) return gmItemCodePromise;
        gmItemCodePromise = fetch('js/00-data.js', { cache: 'no-store' }).then(function (response) {
            if (!response.ok) throw new Error('無法讀取道具資料');
            return response.text();
        }).then(function (text) {
            const codes = {};
            let inItems = false;
            text.split(/\r?\n/).forEach(function (line, index) {
                if (/^\s*items\s*:\s*\{/.test(line)) { inItems = true; return; }
                if (inItems && /^\s*mobs\s*:\s*\{/.test(line)) { inItems = false; return; }
                if (!inItems) return;
                const match = line.match(/^\s*"([^"\\]+)"\s*:\s*\{/);
                if (match && typeof DB !== 'undefined' && DB.items && DB.items[match[1]]) codes[String(index + 1)] = match[1];
            });
            return codes;
        }).catch(function (error) {
            console.warn('GM 道具編號索引建立失敗', error);
            return {};
        });
        return gmItemCodePromise;
    }

    async function resolveItemInput(raw) {
        const value = String(raw || '').trim();
        if (!value || typeof DB === 'undefined' || !DB.items) return null;
        if (DB.items[value]) return value;                         // 原本的內部 ID 仍可使用
        if (/^\d+$/.test(value)) {
            const codes = await loadItemCodeMap();
            if (codes[value]) return codes[value];                 // 新的道具編號（如 479）
        }
        const key = Object.keys(DB.items).find(function (id) { return DB.items[id] && DB.items[id].n === value; });
        return key || null;                                        // 也保留完整名稱搜尋
    }

    function gmItemTypeLabel(item) {
        const labels = { wpn:'武器', arm:'防具', acc:'飾品', consumable:'消耗品', material:'材料', scroll:'卷軸', book:'技能書', misc:'其他' };
        return labels[item && item.type] || String((item && item.type) || '其他');
    }

    // 匯出一份可以離線查詢的 GM 道具表。編號與「一般發放」輸入欄所用的
    // 數字完全相同，採 UTF-8 BOM 讓 Windows 記事本能正確顯示繁體中文。
    window.gmExportItemTxt = async function () {
        if (typeof DB === 'undefined' || !DB.items) {
            const result = document.getElementById('gm-result');
            if (result) result.textContent = '道具資料尚未載入，請稍後再試。';
            return;
        }
        const codeMap = await loadItemCodeMap();
        const reverseCodes = {};
        Object.keys(codeMap).forEach(function (code) { reverseCodes[codeMap[code]] = code; });
        const rows = Object.keys(DB.items).map(function (id) {
            const item = DB.items[id] || {};
            const code = reverseCodes[id] || '-';
            const name = String(item.n || item.name || id).replace(/[\r\n\t]+/g, ' ');
            const slot = item.slot ? ('　部位：' + item.slot) : '';
            return { code:code, line:[code, name, gmItemTypeLabel(item), id + slot].join('\t') };
        }).sort(function (a, b) {
            const an = Number(a.code), bn = Number(b.code);
            if (Number.isFinite(an) && Number.isFinite(bn)) return an - bn;
            if (Number.isFinite(an)) return -1;
            if (Number.isFinite(bn)) return 1;
            return a.line.localeCompare(b.line, 'zh-Hant');
        });
        const text = [
            '天堂放置單機版｜GM 道具編號清單',
            '使用方式：在 GM 的「道具編號」欄直接輸入第一欄數字，再按一般發放或發放 +N 裝備。',
            '欄位：編號\t名稱\t類型\t內部 ID／部位',
            ''
        ].concat(rows.map(function (row) { return row.line; })).join('\r\n');
        const blob = new Blob(['\ufeff' + text], { type:'text/plain;charset=utf-8' });
        const url = URL.createObjectURL(blob);
        const link = document.createElement('a');
        link.href = url;
        link.download = '天堂GM道具編號清單.txt';
        document.body.appendChild(link);
        link.click();
        link.remove();
        setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
        const result = document.getElementById('gm-result');
        if (result) result.textContent = '已匯出 ' + rows.length + ' 筆道具至 TXT，可用編號直接在 GM 發放。';
    };

    function activeCharacter() {
        if (typeof player === 'undefined' || !player || !player.cls) {
            alert('請先建立或載入角色，再使用 GM 控制台。');
            return false;
        }
        return true;
    }

    function onlineGmAllowed() {
        return typeof window.onlineCloudGmAllowed === 'function' && window.onlineCloudGmAllowed();
    }

    function requireOnlineGm() {
        if (onlineGmAllowed()) return true;
        gmResult('GM_REQUIRED');
        return false;
    }

    function numberValue(id, fallback, min, max) {
        const value = Number(document.getElementById(id).value);
        if (!Number.isFinite(value)) return fallback;
        return Math.max(min, Math.min(max, Math.floor(value)));
    }

    function persist(message) {
        try { if (typeof calcStats === 'function') calcStats(); } catch (e) { console.warn(e); }
        try { if (typeof updateUI === 'function') updateUI(); } catch (e) { console.warn(e); }
        try { if (typeof renderTabs === 'function') renderTabs(true); } catch (e) { console.warn(e); }
        try { if (typeof saveGame === 'function') saveGame(); } catch (e) { console.warn(e); }
        const result = document.getElementById('gm-result');
        if (result) result.textContent = message || '已套用並儲存。';
    }

    function renderServerMutation(message) {
        try { if (typeof calcStats === 'function') calcStats(); } catch (e) { console.warn(e); }
        try { if (typeof updateUI === 'function') updateUI(); } catch (e) { console.warn(e); }
        try { if (typeof renderTabs === 'function') renderTabs(true); } catch (e) { console.warn(e); }
        gmResult(message);
    }

    function fillForm() {
        if (!activeCharacter()) return;
        document.getElementById('gm-gold').value = Math.floor(player.gold || 0);
        const sponsorInput = document.getElementById('gm-sponsor-diamonds');
        const sponsorBalance = document.getElementById('gm-sponsor-balance');
        const sponsorValue = typeof window.getSponsorDiamonds === 'function' ? window.getSponsorDiamonds() : Math.max(0, Math.floor(Number(player.sponsorDiamonds) || 0));
        if (sponsorInput) sponsorInput.value = 100;
        if (sponsorBalance) sponsorBalance.textContent = sponsorValue.toLocaleString();
        document.getElementById('gm-level').value = Math.max(1, Math.min(MAX_LEVEL, Math.floor(player.lv || 1)));
        statKeys.forEach(function (key) {
            document.getElementById('gm-' + key).value = Math.floor((player.base && player.base[key]) || 0);
        });
        document.getElementById('gm-result').textContent = '已讀取「' + (player.name || '目前角色') + '」的資料。';
    }

    window.gmToggle = function () {
        if (!onlineGmAllowed()) {
            const deniedPanel = document.getElementById('gm-panel');
            if (deniedPanel) deniedPanel.hidden = true;
            return;
        }
        const panel = document.getElementById('gm-panel');
        if (!panel) return;
        const opening = panel.hidden;
        panel.hidden = !opening;
        if (opening) fillForm();
    };
    window.gmRefresh = fillForm;

    window.gmApplyCharacter = async function () {
        if (!activeCharacter() || !requireOnlineGm()) return;
        const gold = numberValue('gm-gold', player.gold || 0, 0, Number.MAX_SAFE_INTEGER);
        const level = numberValue('gm-level', player.lv || 1, 1, MAX_LEVEL);
        const base = {};
        statKeys.forEach(function (key) { base[key] = numberValue('gm-' + key, (player.base && player.base[key]) || 0, 0, 99); });
        if (player.cloudCharacterId && typeof window.onlineCloudGmMutate === 'function') {
            try { await window.onlineCloudGmMutate('gm.character.apply', { gold:gold, level:level, base:base }); renderServerMutation('GM character update applied by server.'); fillForm(); return; }
            catch (error) { document.getElementById('gm-result').textContent = '雲端套用失敗：' + (error.message || '請稍後再試'); return; }
        }
        player.gold = gold;
        player.lv = level;
        // GM 直接拉高等級也要拿到 Lv50 起每級 1 點的能力點。
        if (typeof ensureLevelBonusPoints === 'function') ensureLevelBonusPoints(player);
        player.exp = 0;
        player.base = base;
        player.hp = player.mhp || player.hp;
        player.mp = player.mmp || player.mp;
        persist('角色數值已套用：Lv.' + player.lv + '、金幣 ' + player.gold.toLocaleString() + '。');
        fillForm();
    };

    window.gmGrantSponsorDiamonds = async function () {
        if (!activeCharacter() || !requireOnlineGm()) return;
        const amount = numberValue('gm-sponsor-diamonds', 0, 1, Number.MAX_SAFE_INTEGER);
        if (player.cloudCharacterId && typeof window.onlineCloudGmGrantDiamonds === 'function') {
            try {
                const balance = await window.onlineCloudGmGrantDiamonds(amount);
                persist('雲端已贈送贊助鑽石 × ' + amount.toLocaleString() + '；目前餘額 ' + Number(balance).toLocaleString() + '。');
                fillForm();
            } catch (error) {
                const result = document.getElementById('gm-result');
                if (result) result.textContent = '雲端贈送失敗：' + (error.message || '請稍後再試。');
            }
            return;
        }
        if (typeof window.adjustSponsorDiamonds === 'function') window.adjustSponsorDiamonds(amount);
        else player.sponsorDiamonds = Math.max(0, Math.floor(Number(player.sponsorDiamonds) || 0)) + amount;
        persist('已贈送贊助鑽石 × ' + amount.toLocaleString() + '。');
        fillForm();
    };

    function gmTargetAccount() {
        return String((document.getElementById('gm-target-account') || {}).value || '').trim().toLowerCase();
    }
    function gmTargetCharacter() {
        return String((document.getElementById('gm-target-character') || {}).value || '').trim();
    }
    function gmResult(message) {
        const result = document.getElementById('gm-result');
        if (result) result.textContent = message;
    }

    window.gmGrantPlayerSponsorDiamonds = async function () {
        if (!requireOnlineGm()) return;
        const account = gmTargetAccount();
        const amount = numberValue('gm-target-diamonds', 0, 1, 1000000000);
        if (!/^[a-z0-9_]{3,20}$/.test(account)) return gmResult('請輸入玩家登入帳號（3～20 碼英文小寫、數字或 _）。');
        if (typeof window.onlineCloudGmGrantPlayerDiamonds !== 'function') return gmResult('雲端 GM 發放功能尚未連線，請重新登入後再試。');
        try {
            const data = await window.onlineCloudGmGrantPlayerDiamonds(account, amount);
            gmResult('已贈送玩家「' + account + '」贊助鑽石 ' + amount.toLocaleString() + '；目前餘額 ' + Number(data.balance || 0).toLocaleString() + '。');
        } catch (error) {
            gmResult('贈送失敗：' + (error.message || '請確認玩家帳號與雲端連線。'));
        }
    };

    window.gmGrantPlayerItem = async function () {
        if (!requireOnlineGm()) return;
        const account = gmTargetAccount();
        const characterName = gmTargetCharacter();
        const input = String((document.getElementById('gm-target-item-id') || {}).value || '').trim();
        const id = await resolveItemInput(input);
        const qty = numberValue('gm-target-item-qty', 1, 1, 99999);
        const requestedEn = numberValue('gm-target-item-en', 0, 0, 15);
        const item = (typeof DB !== 'undefined' && DB.items) ? DB.items[id] : null;
        if (!/^[a-z0-9_]{3,20}$/.test(account)) return gmResult('請輸入玩家登入帳號。');
        if (!characterName) return gmResult('發放道具時必須輸入玩家角色名稱。');
        if (!item) return gmResult('找不到道具，請直接輸入正確的道具編號。');
        if (typeof window.onlineCloudGmGrantPlayerItem !== 'function') return gmResult('雲端 GM 發放功能尚未連線，請重新登入後再試。');
        const cap = typeof enhanceCap === 'function' ? enhanceCap(item) : 15;
        const en = (item.type === 'wpn' || item.type === 'arm' || item.type === 'acc') ? Math.min(requestedEn, cap) : 0;
        try {
            await window.onlineCloudGmGrantPlayerItem(account, characterName, { id:id, cnt:qty, en:en, bless:false, anc:false, attr:false, seteff:false, lock:false, junk:false });
            gmResult('已贈送「' + characterName + '」（帳號 ' + account + '）' + (en ? (' +' + en) : '') + (item.n || id) + ' × ' + qty + '。');
        } catch (error) {
            gmResult('贈送失敗：' + (error.message || '請確認玩家帳號、角色名稱與雲端連線。'));
        }
    };

    window.gmGrantItem = async function () {
        if (!activeCharacter() || !requireOnlineGm()) return;
        const input = (document.getElementById('gm-item-id').value || '').trim();
        const id = await resolveItemInput(input);
        const qty = numberValue('gm-item-qty', 1, 1, 99999);
        if (!id || typeof DB === 'undefined' || !DB.items || !DB.items[id]) {
            document.getElementById('gm-result').textContent = '找不到道具；可直接輸入編號（例如 479）、名稱或原本的 ID。';
            return;
        }
        try {
            const entry = { id:id, cnt:qty, en:0, bless:false, anc:false, attr:false, seteff:false, lock:false, junk:false };
            if (player.cloudCharacterId && typeof window.onlineCloudGmMutate === 'function') {
                await window.onlineCloudGmMutate('gm.inventory.grant', { item:entry });
                renderServerMutation('GM inventory grant applied by server.');
                return;
            }
            gainItem(id, qty, true, true);
            persist('已發放：' + (DB.items[id].n || id) + ' × ' + qty + '。');
        } catch (error) {
            console.error(error);
            document.getElementById('gm-result').textContent = '發放失敗，請確認背包或道具資料。';
        }
    };

    // 強化裝備以獨立物件發放，避免先取得 +0 裝備後再修改，誤把既有的同一堆 +0 裝備一併升級。
    window.gmGrantEnhancedItem = async function () {
        if (!activeCharacter() || !requireOnlineGm()) return;
        const input = (document.getElementById('gm-item-id').value || '').trim();
        const id = await resolveItemInput(input);
        const qty = numberValue('gm-item-qty', 1, 1, 99999);
        const requestedEn = numberValue('gm-item-en', 0, 0, 15);
        const item = (typeof DB !== 'undefined' && DB.items) ? DB.items[id] : null;
        if (!item || (item.type !== 'wpn' && item.type !== 'arm' && item.type !== 'acc')) {
            document.getElementById('gm-result').textContent = '強化發放只適用於武器、防具或飾品；請輸入正確的道具編號、名稱或 ID。';
            return;
        }
        const cap = typeof enhanceCap === 'function' ? enhanceCap(item) : 15;
        const en = Math.min(requestedEn, cap);
        const probe = { id: id, en: en, bless: false, anc: false, attr: false, seteff: false };
        if (player.cloudCharacterId && typeof window.onlineCloudGmMutate === 'function') {
            try {
                await window.onlineCloudGmMutate('gm.inventory.grant', { item:{ id:id, cnt:qty, en:en, bless:false, anc:false, attr:false, seteff:false, lock:false, junk:false } });
                renderServerMutation('GM enhanced inventory grant applied by server.');
                return;
            } catch (error) { document.getElementById('gm-result').textContent = '雲端發放失敗：' + (error.message || '請稍後再試'); return; }
        }
        const existing = (player.inv || []).find(function (entry) {
            return typeof sameItemSig === 'function' && sameItemSig(entry, probe);
        });
        if (existing) existing.cnt = (existing.cnt || 0) + qty;
        else {
            player.inv.push({
                id: id, uid: typeof uid === 'function' ? uid() : ('gm-' + Date.now()), cnt: qty,
                en: en, bless: false, anc: false, attr: false, seteff: false, lock: false, junk: false
            });
        }
        try { if (typeof registerEquipObtained === 'function') registerEquipObtained(id); } catch (e) { console.warn(e); }
        try { if (typeof autoSortInventory === 'function') autoSortInventory(); } catch (e) { console.warn(e); }
        persist('已發放：+' + en + ' ' + (item.n || id) + ' × ' + qty + '。');
    };

    window.gmHeal = function () {
        if (!activeCharacter() || !requireOnlineGm()) return;
        gmResult('ONLINE_GM_HEAL_NOT_IMPLEMENTED');
        return;
        player.dead = false;
        player.hp = player.mhp || player.hp;
        player.mp = player.mmp || player.mp;
        if (player.statuses) Object.keys(player.statuses).forEach(function (key) { player.statuses[key] = 0; });
        persist('角色已復活，HP／MP／異常狀態已重置。');
    };

    // GM 專用：依目前角色職業授予全部可學技能。略過純武器觸發(procOnly)與沒有職業需求的內部技能，
    // 並刻意略過等級／精靈屬性限制；GM 學習後不消耗任何技能書。
    window.gmLearnAllSkills = async function () {
        if (!activeCharacter() || !requireOnlineGm()) return;
        if (typeof DB === 'undefined' || !DB.skills || typeof skillReqLv !== 'function') {
            document.getElementById('gm-result').textContent = '技能資料尚未載入，請稍候後再試。';
            return;
        }
        player.skills = Array.isArray(player.skills) ? player.skills : [];
        const known = new Set(player.skills);
        let learned = 0;
        Object.keys(DB.skills).forEach(function (id) {
            const skill = DB.skills[id];
            if (!skill || skill.procOnly) return;
            if (skillReqLv(skill, id) === undefined) return;
            if (!known.has(id)) { known.add(id); player.skills.push(id); learned++; }
        });
        if (player.cloudCharacterId && typeof window.onlineCloudGmMutate === 'function') {
            try { await window.onlineCloudGmMutate('gm.skills.learn', { skills:player.skills }); renderServerMutation('GM skills update applied by server.'); return; }
            catch (error) { document.getElementById('gm-result').textContent = '雲端學習失敗：' + (error.message || '請稍後再試'); return; }
        }
        try { if (typeof renderSkillSelects === 'function') renderSkillSelects(); } catch (e) { console.warn(e); }
        persist(learned ? ('已學習本職全部技能：新增 ' + learned + ' 項。') : '本職全部技能都已學習。');
    };

    // GM 專用：收藏冊的內容只記錄「已取得」狀態，不會把數百件物品塞入背包。
    // 一次完成裝備、道具、怪物卡片、遺物四本收藏冊，並套用各自的完成加成。
    window.gmCompleteCollections = async function () {
        if (!activeCharacter() || !requireOnlineGm()) return;
        const count = { equip: 0, misc: 0, card: 0, relic: 0 };
        player.equipDex = player.equipDex || {};
        if (typeof EQUIP_ITEM_CAT !== 'undefined') Object.keys(EQUIP_ITEM_CAT).forEach(function (id) {
            if (!player.equipDex[id]) { player.equipDex[id] = true; count.equip++; }
        });
        player.miscDex = player.miscDex || {};
        if (typeof MISC_ITEM_CAT !== 'undefined') Object.keys(MISC_ITEM_CAT).forEach(function (id) {
            if (!player.miscDex[id]) { player.miscDex[id] = true; count.misc++; }
        });
        player.cardDex = player.cardDex || {};
        if (typeof CARD_MOB_INFO !== 'undefined') Object.keys(CARD_MOB_INFO).forEach(function (name) {
            if ((player.cardDex[name] || 0) < 100) { player.cardDex[name] = 100; count.card++; }
        });
        player.relicDex = player.relicDex || {};
        if (typeof RELIC_ITEM_CAT !== 'undefined') Object.keys(RELIC_ITEM_CAT).forEach(function (id) {
            if (!player.relicDex[id]) { player.relicDex[id] = true; count.relic++; }
        });
        if (player.cloudCharacterId && typeof window.onlineCloudGmMutate === 'function') {
            try {
                await window.onlineCloudGmMutate('gm.collections.complete', { collections:{ equipDex:player.equipDex, miscDex:player.miscDex, cardDex:player.cardDex, relicDex:player.relicDex } });
                renderServerMutation('GM collections update applied by server.');
                return;
            } catch (error) { document.getElementById('gm-result').textContent = '雲端收藏更新失敗：' + (error.message || '請稍後再試'); return; }
        }
        try { if (typeof saveEquipDex === 'function') saveEquipDex(); } catch (e) { console.warn(e); }
        try { if (typeof saveMiscDex === 'function') saveMiscDex(); } catch (e) { console.warn(e); }
        try { if (typeof saveCardDex === 'function') saveCardDex(); } catch (e) { console.warn(e); }
        try { if (typeof saveRelicDex === 'function') saveRelicDex(); } catch (e) { console.warn(e); }
        try { if (typeof renderEquipBook === 'function') renderEquipBook(); } catch (e) { console.warn(e); }
        try { if (typeof renderMiscBook === 'function') renderMiscBook(); } catch (e) { console.warn(e); }
        try { if (typeof renderCardBook === 'function') renderCardBook(); } catch (e) { console.warn(e); }
        try { if (typeof renderRelicBook === 'function') renderRelicBook(); } catch (e) { console.warn(e); }
        persist('收藏已全滿：裝備 +' + count.equip + '、道具 +' + count.misc + '、怪物 +' + count.card + '、遺物 +' + count.relic + '。');
    };

    window.gmMaxLevel = function () {
        if (!activeCharacter()) return;
        document.getElementById('gm-level').value = MAX_LEVEL;
        window.gmApplyCharacter();
    };

    function itemOptions() {
        if (typeof DB === 'undefined' || !DB.items) return '';
        return Object.keys(DB.items).sort(function (a, b) {
            return (DB.items[a].name || a).localeCompare(DB.items[b].name || b, 'zh-Hant');
        }).map(function (id) {
            const item = DB.items[id];
            return '<option value="' + id.replace(/"/g, '&quot;') + '" label="' + String(item.name || id).replace(/"/g, '&quot;') + '"></option>';
        }).join('');
    }

    function buildPanel() {
        const style = document.createElement('style');
        style.textContent = `
            #gm-toggle { position:fixed; right:18px; bottom:18px; z-index:9998; border:1px solid #fbbf24; border-radius:999px; padding:10px 16px; background:#4a2600; color:#fde68a; font:700 15px system-ui; cursor:pointer; box-shadow:0 4px 18px #000a; }
            #gm-panel { position:fixed; right:18px; bottom:68px; z-index:9999; width:min(440px,calc(100vw - 28px)); max-height:calc(100vh - 90px); overflow:auto; border:1px solid #d97706; border-radius:14px; background:#111827; color:#e5e7eb; box-shadow:0 18px 60px #000c; font:14px system-ui; }
            #gm-panel[hidden] { display:none; } #gm-panel * { box-sizing:border-box; } .gm-head { display:flex; justify-content:space-between; align-items:center; padding:14px 16px; background:linear-gradient(90deg,#431407,#78350f); } .gm-head strong { color:#fde68a; font-size:17px; } .gm-close,.gm-btn { border:1px solid #64748b; border-radius:7px; padding:8px 10px; background:#334155; color:#fff; cursor:pointer; font-weight:700; } .gm-btn:hover,.gm-close:hover { filter:brightness(1.15); } .gm-content { padding:14px; } .gm-section { margin:0 0 15px; padding:12px; border:1px solid #334155; border-radius:9px; } .gm-section h3 { margin:0 0 10px; color:#fcd34d; font-size:14px; } .gm-grid { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:8px; } .gm-grid.stats { grid-template-columns:repeat(3,minmax(0,1fr)); } .gm-label { display:flex; flex-direction:column; gap:4px; color:#cbd5e1; font-size:12px; } .gm-input { width:100%; min-width:0; padding:7px 8px; border:1px solid #475569; border-radius:6px; background:#020617; color:#f8fafc; } .gm-actions { display:flex; flex-wrap:wrap; gap:8px; margin-top:10px; } .gm-primary { background:#92400e; border-color:#f59e0b; } #gm-result { min-height:20px; margin:8px 2px 0; color:#a7f3d0; font-size:12px; }
        `;
        document.head.appendChild(style);
        const root = document.createElement('div');
        root.innerHTML = `
            <button id="gm-toggle" type="button" style="display:none" onclick="gmToggle()" title="GM 控制台（F10）">GM</button>
            <aside id="gm-panel" hidden aria-label="GM 控制台">
                <div class="gm-head"><strong>單機 GM 控制台</strong><button class="gm-close" type="button" onclick="gmToggle()">關閉</button></div>
                <div class="gm-content">
                    <section class="gm-section"><h3>目前角色</h3>
                        <div class="gm-grid"><label class="gm-label">金幣<input id="gm-gold" class="gm-input" type="number" min="0" step="1"></label><label class="gm-label">等級（1–75）<input id="gm-level" class="gm-input" type="number" min="1" max="75" step="1"></label></div>
                        <div class="gm-grid" style="margin-top:8px"><label class="gm-label">贊助鑽石（本次贈送數量）<input id="gm-sponsor-diamonds" class="gm-input" type="number" value="100" min="1" step="1"></label><label class="gm-label">目前贊助鑽石<input id="gm-sponsor-balance" class="gm-input" type="text" readonly></label></div>
                        <div class="gm-actions"><button class="gm-btn gm-primary" type="button" onclick="gmGrantSponsorDiamonds()">贈送贊助鑽石</button></div>
                        <div class="gm-grid stats" style="margin-top:8px"><label class="gm-label">力量<input id="gm-str" class="gm-input" type="number" min="0" max="99"></label><label class="gm-label">敏捷<input id="gm-dex" class="gm-input" type="number" min="0" max="99"></label><label class="gm-label">體質<input id="gm-con" class="gm-input" type="number" min="0" max="99"></label><label class="gm-label">智力<input id="gm-int" class="gm-input" type="number" min="0" max="99"></label><label class="gm-label">精神<input id="gm-wis" class="gm-input" type="number" min="0" max="99"></label><label class="gm-label">魅力<input id="gm-cha" class="gm-input" type="number" min="0" max="99"></label></div>
                        <div class="gm-actions"><button class="gm-btn gm-primary" type="button" onclick="gmApplyCharacter()">套用角色數值</button><button class="gm-btn" type="button" onclick="gmMaxLevel()">升至滿級</button><button class="gm-btn" type="button" onclick="gmHeal()">復活／全補</button></div>
                    </section>
                    <section class="gm-section"><h3>發放道具</h3>
                        <div class="gm-grid"><label class="gm-label" style="grid-column:1/-1">道具編號（直接輸入數字即可）<input id="gm-item-id" class="gm-input" list="gm-item-list" inputmode="numeric" placeholder="例如：479（真．冥皇執行劍）"></label><label class="gm-label">數量<input id="gm-item-qty" class="gm-input" type="number" value="1" min="1" max="99999"></label><label class="gm-label">強化值（武器／防具／飾品）<input id="gm-item-en" class="gm-input" type="number" value="0" min="0" max="15"></label></div>
                        <datalist id="gm-item-list">${itemOptions()}</datalist><div class="gm-actions"><button class="gm-btn gm-primary" type="button" onclick="gmGrantItem()">一般發放</button><button class="gm-btn gm-primary" type="button" onclick="gmGrantEnhancedItem()">發放 +N 裝備／飾品</button><button class="gm-btn" type="button" onclick="gmExportItemTxt()">匯出道具 TXT</button></div>
                    </section>
                    <section class="gm-section"><h3>線上玩家贈送</h3>
                        <div style="color:#cbd5e1;font-size:12px;line-height:1.55;margin-bottom:8px">輸入玩家的登入帳號即可贈送贊助鑽石；道具則再填入該玩家的角色名稱。所有動作都會記錄於 GM 稽核紀錄。</div>
                        <div class="gm-grid"><label class="gm-label">玩家登入帳號<input id="gm-target-account" class="gm-input" type="text" maxlength="20" autocomplete="off" placeholder="例如：player01"></label><label class="gm-label">玩家角色名稱（道具必填）<input id="gm-target-character" class="gm-input" type="text" maxlength="20" autocomplete="off" placeholder="例如：小白"></label></div>
                        <div class="gm-grid" style="margin-top:8px"><label class="gm-label">贈送贊助鑽石<input id="gm-target-diamonds" class="gm-input" type="number" value="100" min="1" step="1"></label><div class="gm-actions" style="align-self:end"><button class="gm-btn gm-primary" type="button" onclick="gmGrantPlayerSponsorDiamonds()">贈送鑽石給玩家</button></div></div>
                        <div class="gm-grid" style="margin-top:8px"><label class="gm-label" style="grid-column:1/-1">道具編號（直接輸入數字即可）<input id="gm-target-item-id" class="gm-input" list="gm-item-list" inputmode="numeric" placeholder="例如：479"></label><label class="gm-label">數量<input id="gm-target-item-qty" class="gm-input" type="number" value="1" min="1" max="99999"></label><label class="gm-label">強化值（武器／防具／飾品）<input id="gm-target-item-en" class="gm-input" type="number" value="0" min="0" max="15"></label></div>
                        <div class="gm-actions"><button class="gm-btn gm-primary" type="button" onclick="gmGrantPlayerItem()">贈送道具給玩家</button></div>
                    </section>
                    <section class="gm-section"><h3>技能與魔法</h3>
                        <div style="color:#cbd5e1;font-size:12px;line-height:1.5">直接學習目前職業的全部可學技能，略過純武器觸發技能；不需要技能書，也不受等級或元素條件限制。</div>
                        <div class="gm-actions"><button class="gm-btn gm-primary" type="button" onclick="gmLearnAllSkills()">一鍵學習本職魔法</button></div>
                    </section>
                    <section class="gm-section"><h3>收藏</h3>
                        <div style="color:#cbd5e1;font-size:12px;line-height:1.5">一次解鎖裝備、道具、怪物卡片與遺物全部收藏，不會把物品加入背包。</div>
                        <div class="gm-actions"><button class="gm-btn gm-primary" type="button" onclick="gmCompleteCollections()">一鍵收藏滿</button></div>
                    </section>
                    <div id="gm-result">按「讀取」或直接修改後套用。</div>
                    <div class="gm-actions"><button class="gm-btn" type="button" onclick="gmRefresh()">讀取目前角色</button></div>
                </div>
            </aside>`;
        document.body.appendChild(root);
    }

    function init() {
        buildPanel();
        window.addEventListener('keydown', function (event) {
            if (event.key === 'F10' && onlineGmAllowed()) { event.preventDefault(); window.gmToggle(); }
        });
    }

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
    else init();
})();
