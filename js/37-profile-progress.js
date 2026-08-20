/* Readable EXP and rate display for the left character card. */
(function () {
    function number(value) {
        return Math.max(0, Math.floor(Number(value) || 0)).toLocaleString();
    }
    function serverRate(key) {
        const config = typeof window.runtimeConfig === 'function' ? window.runtimeConfig() : {};
        const value = Number(config && config[key]);
        const base = Number.isFinite(value) && value > 0 ? value : 1;
        const passKind = { exp_multiplier:'exp', gold_multiplier:'gold', drop_rate_multiplier:'drop' }[key];
        return base * (passKind ? passMultiplier(passKind) : 1);
    }
    function passMultiplier(kind) {
        if (kind === 'drop' && typeof window.sponsorDropMultiplier === 'function') {
            return Math.max(1, Number(window.sponsorDropMultiplier()) || 1);
        }
        if (typeof window.sponsorGetMultiplier === 'function') {
            return Math.max(1, Number(window.sponsorGetMultiplier(kind)) || 1);
        }
        return 1;
    }
    function passTags() {
        if (typeof window.sponsorPassHudStatus !== 'function') return '';
        return window.sponsorPassHudStatus().map(function (pass) {
            return `<span class="pass-${pass.kind}">${pass.label} ${pass.days}天</span>`;
        }).join('');
    }
    function ensureRows() {
        const bar = document.getElementById('bar-exp');
        if (!bar || !bar.parentElement) return null;
        let detail = document.getElementById('profile-exp-detail');
        if (!detail) {
            detail = document.createElement('div');
            detail.id = 'profile-exp-detail';
            bar.parentElement.insertAdjacentElement('afterend', detail);
        }
        let rates = document.getElementById('profile-rate-summary');
        if (!rates) {
            rates = document.createElement('div');
            rates.id = 'profile-rate-summary';
            rates.className = 'profile-rate-summary';
            detail.insertAdjacentElement('afterend', rates);
        }
        return { detail, rates };
    }
    function refresh() {
        if (typeof player === 'undefined' || typeof getExpReq !== 'function') return;
        const rows = ensureRows();
        if (!rows) return;
        const need = Math.max(0, Number(getExpReq(player.lv)) || 0);
        const current = Math.max(0, Number(player.exp) || 0);
        const left = Math.max(0, need - current);
        const pct = player.lv >= PLAYER_LEVEL_CAP ? 100 : (need ? Math.min(100, current / need * 100) : 0);
        const expText = document.getElementById('txt-exp');
        if (expText) expText.textContent = `EXP  ${pct.toFixed(2)}%`;
        rows.detail.innerHTML = `<span>EXP <b>${number(current)}</b> / ${number(need)}</span><span>Next <b>${number(left)}</b></span>`;
        rows.rates.innerHTML = `<div class="profile-rate-server"><span class="rate-exp">⚔ 經驗 x${serverRate('exp_multiplier').toFixed(2)}</span><span class="rate-gold">💰 金幣 x${serverRate('gold_multiplier').toFixed(2)}</span><span class="rate-drop">🎁 掉落 x${serverRate('drop_rate_multiplier').toFixed(2)}</span></div><div class="profile-rate-passes">${passTags()}</div>`;
    }
    window.refreshProfileProgress = refresh;
    setInterval(refresh, 250);
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', refresh);
    else refresh();
}());
