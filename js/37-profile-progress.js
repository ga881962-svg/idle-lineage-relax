/* Readable EXP and rate display for the left character card. */
(function () {
    function number(value) {
        return Math.max(0, Math.floor(Number(value) || 0)).toLocaleString();
    }
    function rate(kind) {
        if (typeof window.sponsorGetMultiplier === 'function') {
            return Math.max(1, Number(window.sponsorGetMultiplier(kind)) || 1);
        }
        return 1;
    }
    function dropRate() {
        if (typeof window.sponsorDropMultiplier === 'function') {
            return Math.max(1, Number(window.sponsorDropMultiplier()) || 1);
        }
        return 1;
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
        let rates = document.getElementById('profile-rate-tags');
        if (!rates) {
            rates = document.createElement('div');
            rates.id = 'profile-rate-tags';
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
        rows.rates.innerHTML = `<span class="rate-exp">EXP x${rate('exp').toFixed(2)}</span><span class="rate-gold">GOLD x${rate('gold').toFixed(2)}</span><span class="rate-drop">DROP x${dropRate().toFixed(2)}</span>`;
    }
    window.refreshProfileProgress = refresh;
    setInterval(refresh, 250);
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', refresh);
    else refresh();
}());
