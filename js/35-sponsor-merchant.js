// 贊助使者：所有村莊共用的 30 天加成商店。
// 離線掛機月卡由伺服器驗證、計時與結算；瀏覽器只顯示狀態與購買結果。
(function () {
    const DAYS_30 = 30 * 24 * 60 * 60 * 1000;
    const PASSES = {
        exp:     { name: '經驗加倍 x1.2（30 天）', price: 199, multiplier: 1.2, note: '打怪獲得的經驗值提高 20%。' },
        gold:    { name: '金幣加倍 x1.2（30 天）', price: 199, multiplier: 1.2, note: '怪物掉落的金幣提高 20%。' },
        drop:    { name: '掉落加倍 x1.2（30 天）', price: 199, multiplier: 1.2, note: '怪物的物品掉落機率提高 20%。' },
        offline: { name: '離線掛機（30 天）', price: 599, multiplier: 1, note: '離線期間由伺服器結算經驗、金幣與物品，並可返回最後允許的練功地圖。' }
    };
    // The offline pass is intentionally different from the legacy visual
    // boosters: its validity and purchase balance are always read from the
    // server, never from a save file or the browser clock.
    // Pass authority is server-only.  `player.sponsorPasses` is intentionally
    // never read or written here: it may be retained in old saves for display
    // compatibility, but cannot grant a multiplier or offline permission.
    let sponsorPassStatus = { loaded:false, loading:false, passes:{}, sponsorDiamonds:null };
    function currentPlayer() { return typeof player !== 'undefined' ? player : null; }
    // Sponsor Diamonds are the renamed shared Pandora currency.  Keep the old
    // storage API for save-file compatibility, but show one currency everywhere.
    function sponsorDiamonds() {
        let p = currentPlayer();
        if (!p) return 0;
        if (typeof window.pandoraGetSharedDiamonds === 'function' && typeof window.pandoraAdjustSharedDiamonds === 'function') {
            // Preserve any diamonds granted by the previous GM version once.
            if (!p.sponsorDiamondMigrationV2) {
                let legacy = Math.max(0, Math.floor(Number(p.sponsorDiamonds) || 0));
                if (legacy) window.pandoraAdjustSharedDiamonds(legacy);
                p.sponsorDiamonds = 0;
                p.sponsorDiamondMigrationV2 = true;
            }
            return Math.max(0, Math.floor(Number(window.pandoraGetSharedDiamonds()) || 0));
        }
        p.sponsorDiamonds = Math.max(0, Math.floor(Number(p.sponsorDiamonds) || 0));
        return p.sponsorDiamonds;
    }
    function adjustSponsorDiamonds(delta) {
        let p = currentPlayer();
        if (!p) return { ok:false, error:'no character' };
        let amount = Math.floor(Number(delta) || 0);
        if (typeof window.pandoraAdjustSharedDiamonds === 'function') {
            let result = window.pandoraAdjustSharedDiamonds(amount);
            return result && result.ok ? { ok:true, value:Math.max(0, Number(result.diamonds) || 0) } : { ok:false, error:(result && result.error) || 'insufficient sponsor diamonds' };
        }
        let next = sponsorDiamonds() + amount;
        if (next < 0) return { ok:false, error:'insufficient sponsor diamonds' };
        p.sponsorDiamonds = next;
        return { ok:true, value:next };
    }
    window.getSponsorDiamonds = sponsorDiamonds;
    window.adjustSponsorDiamonds = adjustSponsorDiamonds;
    function offlineOnlineReady() {
        return typeof window.onlineCloudApi === 'function'
            && typeof window.onlineCloudCharacterId === 'function' && !!window.onlineCloudCharacterId()
            && typeof window.onlineCloudSessionToken === 'function' && !!window.onlineCloudSessionToken();
    }
    async function refreshSponsorPasses() {
        if (sponsorPassStatus.loading || !offlineOnlineReady()) return sponsorPassStatus;
        sponsorPassStatus.loading = true;
        try {
            const result = await window.onlineCloudApi({
                action:'sponsor.status', characterId:window.onlineCloudCharacterId(),
                requestId:typeof window.onlineCloudRequestId === 'function' ? window.onlineCloudRequestId() : ''
            });
            sponsorPassStatus = {
                loaded:true, loading:false,
                passes:(result && result.passes && typeof result.passes === 'object') ? result.passes : {},
                sponsorDiamonds:Number((result && result.sponsorDiamonds) || 0)
            };
        } catch (error) {
            sponsorPassStatus.loading = false;
            console.warn('sponsor pass status unavailable', error);
        }
        return sponsorPassStatus;
    }
    function untilFor(kind) {
        return sponsorPassStatus.loaded ? (Date.parse(sponsorPassStatus.passes[kind]) || 0) : 0;
    }
    function active(kind) { return untilFor(kind) > Date.now(); }
    function remaining(kind) { let ms = Math.max(0, untilFor(kind) - Date.now()); return ms ? ('剩餘 ' + Math.ceil(ms / 86400000) + ' 天') : '未啟用'; }
    window.sponsorGetMultiplier = function (kind) { return active(kind) && PASSES[kind] ? PASSES[kind].multiplier : 1; };
    window.sponsorDropMultiplier = function () { return window.sponsorGetMultiplier('drop'); };

    window.ensureTownSponsorMerchants = function () {
        if (typeof DB === 'undefined' || !DB.towns) return;
        Object.keys(DB.towns).forEach(function (townId) {
            let town = DB.towns[townId];
            if (!town || !Array.isArray(town.npcs)) return;
            let found = town.npcs.findIndex(function (n) { return n && n.id === 'npc_sponsor'; });
            let sponsor = found >= 0 ? town.npcs.splice(found, 1)[0] : { id: 'npc_sponsor', n: '贊助使者', title: '贊助領取', type: 'sponsor', d: '提供經驗、金幣與掉寶加倍服務，以及即將開放的離線掛機使用權。' };
            // Put it first so it is visible without scrolling through a busy town.
            town.npcs.unshift(sponsor);
        });
    };

    window.renderSponsorMerchant = function (div) {
        if (!div) return;
        let diamonds = sponsorPassStatus.loaded && Number.isFinite(sponsorPassStatus.sponsorDiamonds)
            ? sponsorPassStatus.sponsorDiamonds : sponsorDiamonds();
        let rows = Object.keys(PASSES).map(function (kind) {
            let pass = PASSES[kind], on = active(kind), enough = diamonds >= pass.price;
            return '<div class="sponsor-shop-row"><div class="sponsor-shop-copy"><div class="sponsor-shop-name">' + pass.name + '</div><div class="sponsor-shop-note">' + pass.note + '</div><div class="sponsor-shop-status ' + (on ? 'is-active' : '') + '">' + (on ? ('✓ 已啟用・' + remaining(kind)) : '尚未啟用') + '</div></div><div class="sponsor-shop-buy"><span class="sponsor-diamond">◆ ' + pass.price + '</span><button class="btn ' + (enough ? 'sponsor-buy-ready' : 'sponsor-buy-disabled') + '" ' + (enough ? '' : 'disabled') + ' onclick="sponsorBuy(\'' + kind + '\')">' + (enough ? '購買 30 天' : '鑽石不足') + '</button></div></div>';
        }).join('');
        div.innerHTML = '<div class="sponsor-merchant"><div class="sponsor-merchant-head"><div><div class="sponsor-title">贊助使者 <span>[贊助領取]</span></div><p>歡迎，冒險者。所有加成可以續購並累加天數。</p></div><div class="sponsor-balance">◆ 贊助鑽石：<b>' + Number(diamonds || 0).toLocaleString() + '</b></div></div><div class="sponsor-shop-list">' + rows + '</div></div>';
        if (!sponsorPassStatus.loaded && !sponsorPassStatus.loading && offlineOnlineReady()) {
            refreshSponsorPasses().then(function () {
                if (document.getElementById('interaction-content') === div) window.renderSponsorMerchant(div);
            });
        }
    };
    window.sponsorBuy = async function (kind) {
        let pass = PASSES[kind]; if (!pass || !currentPlayer()) return;
        if (!offlineOnlineReady()) { if (typeof logSys === 'function') logSys('<span class="text-red-300">請先登入雲端帳號後再購買贊助券。</span>'); return; }
        try {
            const result = await window.onlineCloudApi({ action:'sponsor.pass.purchase', characterId:window.onlineCloudCharacterId(), kind:kind, requestId:typeof window.onlineCloudRequestId === 'function' ? window.onlineCloudRequestId() : '' });
            sponsorPassStatus.sponsorDiamonds = Number(result.sponsorDiamonds || 0);
            sponsorPassStatus.passes = Object.assign({}, sponsorPassStatus.passes, (function(){ let p={}; p[kind]=String(result.expiresAt || ''); return p; }()));
            sponsorPassStatus.loaded = true;
            if (typeof logSys === 'function') logSys('<span class="text-amber-300 font-bold">贊助使者：已購買 ' + pass.name + '，目前 ' + remaining(kind) + '。</span>');
            if (typeof updateUI === 'function') updateUI();
            window.renderSponsorMerchant(document.getElementById('interaction-content'));
        } catch (error) {
            console.warn('sponsor pass purchase failed', error);
            if (typeof logSys === 'function') logSys('<span class="text-red-300">贊助券購買失敗，請重新登入後再試。</span>');
        }
    };
    function renderStatusRates() {
        let panel = document.getElementById('status-panel'); if (!panel || !currentPlayer()) return;
        let old = panel.querySelector('.sponsor-rate-summary');
        if (old) old.remove();
        if (typeof window.refreshProfileProgress === 'function') window.refreshProfileProgress();
    }
    window.ensureTownSponsorMerchants();
    // 08-items-equip.js loads before the shared-market module. Refresh once
    // after both modules are available so the profile card never briefly keeps 0.
    setTimeout(function () {
        sponsorDiamonds();
        if (typeof updateUI === 'function') updateUI();
    }, 0);
    setInterval(renderStatusRates, 750);
    function refreshTownCardIfNeeded() {
        window.ensureTownSponsorMerchants();
        try {
            var townId = window.mapState && mapState.current;
            var cards = document.getElementById('town-npc-container');
            if (!townId || !DB.towns[townId] || !cards || cards.classList.contains('hidden')) return;
            if (!cards.querySelector('[data-npc-id="npc_sponsor"]') && typeof renderTownNPCs === 'function') renderTownNPCs(townId);
        } catch (e) {}
    }
    setTimeout(function () { renderStatusRates(); refreshTownCardIfNeeded(); }, 0);
    setInterval(refreshTownCardIfNeeded, 1000);
})();
