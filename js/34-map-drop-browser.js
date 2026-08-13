/*
 * 目前地圖掉落一覽
 * 不另外維護清單，而是直接讀取實際戰鬥使用的掉落表，因此每張地圖與玩家職業
 * 都會顯示正確、目前可取得的物品與機率。
 */
(function () {
    'use strict';

    function esc(v) {
        return String(v == null ? '' : v).replace(/[&<>'"]/g, function (c) {
            return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' })[c];
        });
    }
    function mapName() {
        var sel = document.getElementById('map-select');
        return sel && sel.selectedOptions && sel.selectedOptions[0] ? sel.selectedOptions[0].textContent.trim() : '目前地圖';
    }
    function allowed(id) {
        try { return !(typeof trialDropBlocked === 'function' && trialDropBlocked(id)); } catch (e) { return true; }
    }
    function readDrops(name, isBoss) {
        var out = {}, tables = [];
        var panaceaIds = ['panacea_str', 'panacea_dex', 'panacea_con', 'panacea_int', 'panacea_wis', 'panacea_cha'];
        [
            typeof MOB_DROPS !== 'undefined' ? MOB_DROPS : null,
            typeof DARK_WEAPON_DROPS !== 'undefined' ? DARK_WEAPON_DROPS : null,
            typeof DARK_CRYSTAL_DROPS !== 'undefined' ? DARK_CRYSTAL_DROPS : null,
            typeof DRAGON_DROPS !== 'undefined' ? DRAGON_DROPS : null,
            typeof WARRIOR_DROPS !== 'undefined' ? WARRIOR_DROPS : null,
            typeof MEM_DROPS !== 'undefined' ? MEM_DROPS : null
        ].forEach(function (table) { if (table && table[name]) tables.push(table[name]); });
        tables.forEach(function (list) {
            list.forEach(function (entry) {
                var id = Array.isArray(entry) ? entry[0] : entry;
                var chance = Array.isArray(entry) && isFinite(Number(entry[1])) ? Number(entry[1]) : null;
                if (!id || !DB.items[id] || !allowed(id)) return;
                // 萬能藥由擊殺系統統一判定，舊表中的個別王專屬數值不再採用。
                if (panaceaIds.indexOf(id) !== -1) return;
                if (!out[id]) out[id] = { id: id, chance: 0, unknown: false };
                if (chance == null) out[id].unknown = true;
                else out[id].chance += chance;
            });
        });
        // 每隻王皆有 0.001% 的萬能藥掉落；六種屬性為等機率隨機，因此個別藥水為 1/6。
        if (isBoss) panaceaIds.forEach(function (id) {
            if (DB.items[id] && allowed(id)) out[id] = { id: id, chance: 0.001 / panaceaIds.length, unknown: false };
        });
        return Object.keys(out).map(function (id) { return out[id]; }).sort(function (a, b) {
            return (b.chance || 0) - (a.chance || 0) || DB.items[a.id].n.localeCompare(DB.items[b.id].n, 'zh-Hant');
        });
    }
    function chanceText(drop) {
        if (drop.unknown) return '機率未設定';
        var c = drop.chance;
        if (c >= 1) return (Number.isInteger(c) ? c : c.toFixed(2)) + '%';
        if (c >= 0.01) return c.toFixed(2).replace(/0+$/, '').replace(/\.$/, '') + '%';
        return c.toFixed(4).replace(/0+$/, '').replace(/\.$/, '') + '%';
    }
    function chanceClass(c) {
        if (c >= 1) return 'map-drop-common';
        if (c >= 0.01) return 'map-drop-rare';
        return 'map-drop-ultra';
    }
    function getPool() {
        if (typeof DB === 'undefined' || !DB.maps || typeof mapState === 'undefined') return [];
        var p = DB.maps[mapState.current];
        return Array.isArray(p) ? p : [];
    }
    function createModal() {
        var node = document.createElement('div');
        node.id = 'map-drop-modal';
        node.className = 'hidden';
        node.innerHTML = '<div class="map-drop-shade" onclick="mapDropsBackdrop(event)"></div><section class="map-drop-window" role="dialog" aria-modal="true" aria-labelledby="map-drop-title"><header><h2 id="map-drop-title">📜 掉落一覽</h2><button type="button" onclick="closeMapDrops()" aria-label="關閉">×</button></header><div id="map-drop-content"></div></section>';
        document.body.appendChild(node);
        return node;
    }
    window.openMapDrops = function () {
        var modal = document.getElementById('map-drop-modal') || createModal();
        var pool = getPool(), seen = {}, rows = [], total = 0;
        pool.forEach(function (mid) {
            if (seen[mid] || !DB.mobs[mid]) return;
            seen[mid] = true;
            var mob = DB.mobs[mid], drops = readDrops(mob.n, mob.boss === true);
            total += drops.length;
            var chips = drops.length ? drops.map(function (drop) {
                var item = DB.items[drop.id], nameClass = typeof getItemColor === 'function' ? getItemColor({ id: drop.id }) : '';
                return '<span class="map-drop-chip ' + esc(nameClass) + '" title="' + esc(item.n + '：' + chanceText(drop)) + '">' + esc(item.n) + ' <b class="' + chanceClass(drop.chance) + '">' + chanceText(drop) + '</b></span>';
            }).join('') : '<span class="map-drop-none">此怪物沒有設定專屬掉落。</span>';
            rows.push({ lv: Number(mob.lv) || 0, html: '<article class="map-drop-mob"><h3 class="' + (mob.boss ? 'map-drop-boss' : '') + '">' + (mob.boss ? '👑 ' : '') + esc(mob.n) + ' <small>Lv.' + esc(mob.lv) + ' · ' + drops.length + ' 種</small></h3><div class="map-drop-chips">' + chips + '</div></article>' });
        });
        rows.sort(function (a, b) { return a.lv - b.lv; });
        var content = document.getElementById('map-drop-content');
        content.innerHTML = '<p class="map-drop-summary">共 <b>' + rows.length + '</b> 種怪物・<b>' + total + '</b> 項掉落；顯示的是目前職業可取得的實際掉落與基礎機率。</p>' + (rows.length ? rows.map(function (r) { return r.html; }).join('') : '<p class="map-drop-empty">此處為安全區或尚未設定怪物。</p>');
        document.getElementById('map-drop-title').innerHTML = '📜 掉落一覽 <span>' + esc(mapName()) + '</span>';
        modal.classList.remove('hidden');
        document.body.classList.add('map-drop-open');
    };
    window.closeMapDrops = function () {
        var modal = document.getElementById('map-drop-modal');
        if (modal) modal.classList.add('hidden');
        document.body.classList.remove('map-drop-open');
    };
    window.mapDropsBackdrop = function (event) { if (event.target.classList.contains('map-drop-shade')) closeMapDrops(); };
    window.addEventListener('keydown', function (event) { if (event.key === 'Escape') closeMapDrops(); });
}());
