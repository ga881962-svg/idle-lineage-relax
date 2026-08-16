(function () {
  'use strict';

  const PAGE_SIZE = 60;
  const $ = selector => document.querySelector(selector);
  const esc = value => String(value ?? '').replace(/[&<>'"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[c]));
  const content = $('#wiki-content');
  const count = $('#wiki-count');
  const search = $('#wiki-search');
  const pagination = $('#wiki-pagination');
  let active = new URLSearchParams(location.search).get('tab') || 'items';
  let page = 1;

  const itemList = () => GameSiteData.getItems().filter(Boolean);
  const nameOf = item => item?.name || item?.n || '';
  const typeOf = item => ({ wpn: '武器', arm: '防具', acc: '飾品', skillbk: '法書', weapon: '武器', armor: '防具', accessory: '飾品', item: '道具', material: '材料', book: '法書' }[item?.type] || item?.type || '道具');
  const imageTag = (src, alt, fallback) => src ? `<img src="${esc(src)}" alt="${esc(alt)}" loading="lazy" onerror="this.onerror=null;this.src='${esc(fallback)}'">` : `<span class="wiki-thumb-placeholder" aria-hidden="true">?</span>`;

  function itemStats(item) {
    const stats = [];
    if (item.dmgS != null || item.dmgL != null) stats.push(`傷害 ${item.dmgS ?? '?'}／${item.dmgL ?? '?'}`);
    if (item.ac != null) stats.push(`AC ${item.ac}`);
    if (item.hit) stats.push(`命中 +${item.hit}`);
    if (item.p != null) stats.push(`售價 ${Number(item.p).toLocaleString()}`);
    if (item.safe != null) stats.push(`安全強化 +${item.safe}`);
    return stats;
  }

  function mobStats(mob) { return [`HP ${mob.hp ?? '?'}`, `AC ${mob.ac ?? '?'}`, `MR ${mob.mr ?? '?'}`, `EXP ${mob.exp ?? 0}`]; }

  function pagedRows(rows) {
    const totalPages = Math.max(1, Math.ceil(rows.length / PAGE_SIZE));
    page = Math.min(Math.max(1, page), totalPages);
    const start = (page - 1) * PAGE_SIZE;
    return { totalPages, visible: rows.slice(start, start + PAGE_SIZE), start };
  }

  function renderPagination(totalRows, totalPages) {
    if (totalRows <= PAGE_SIZE) {
      pagination.innerHTML = totalRows ? `<span>第 1 / 1 頁・共 ${totalRows} 筆</span>` : '';
      return;
    }
    const pages = [];
    for (let n = 1; n <= totalPages; n += 1) pages.push(`<button type="button" data-page="${n}" class="${n === page ? 'is-active' : ''}" aria-label="第 ${n} 頁">${n}</button>`);
    pagination.innerHTML = `<button type="button" data-page="${page - 1}" ${page === 1 ? 'disabled' : ''}>← 上一頁</button><div class="wiki-page-numbers">${pages.join('')}</div><button type="button" data-page="${page + 1}" ${page === totalPages ? 'disabled' : ''}>下一頁 →</button><span>第 ${page} / ${totalPages} 頁・共 ${totalRows} 筆</span>`;
  }

  function renderItems(term) {
    const rows = itemList().filter(item => `${nameOf(item)} ${item.id || ''}`.toLowerCase().includes(term));
    const { totalPages, visible, start } = pagedRows(rows);
    count.textContent = rows.length ? `第 ${start + 1}～${start + visible.length} 件／共 ${rows.length} 件物品` : '找不到符合的物品';
    content.innerHTML = visible.length ? `<div class="wiki-grid">${visible.map(item => {
      const name = nameOf(item);
      const stats = itemStats(item);
      return `<article class="wiki-card wiki-card--entity"><div class="wiki-thumb">${imageTag(GameSiteData.itemImage(item), name, GameSiteData.image('assets/ui/item-fallback.png'))}</div><div class="wiki-card-main"><h2>${esc(name || item.id)}</h2><p>${esc(item.desc || item.description || '目前遊戲內物品資料。')}</p><div class="wiki-meta"><span>${esc(typeOf(item))}</span>${stats.map(stat => `<span>${esc(stat)}</span>`).join('')}</div></div></article>`;
    }).join('')}</div>` : '<p class="muted">找不到符合的物品。</p>';
    renderPagination(rows.length, totalPages);
  }

  function renderMobs(term) {
    const rows = GameSiteData.getMobs().filter(mob => `${mob.name || ''} ${mob.id || ''}`.toLowerCase().includes(term));
    const { totalPages, visible, start } = pagedRows(rows);
    count.textContent = rows.length ? `第 ${start + 1}～${start + visible.length} 隻／共 ${rows.length} 隻怪物` : '找不到符合的怪物';
    content.innerHTML = visible.length ? `<div class="wiki-grid">${visible.map(mob => {
      const name = mob.name;
      const stats = mobStats(mob);
      const maps = GameSiteData.mapsForMob(mob);
      const drops = GameSiteData.mobDropEntries(mob);
      const dropPreview = drops.slice(0, 5).map(entry => `${nameOf(entry.item) || entry.itemId} ${entry.rate}%`).join('、');
      return `<article class="wiki-card wiki-card--entity"><div class="wiki-thumb wiki-thumb--mob">${imageTag(GameSiteData.mobImage(mob), name, GameSiteData.image('assets/ui/monster-fallback.png'))}</div><div class="wiki-card-main"><h2>${esc(name || mob.id)}</h2><p>Lv.${esc(mob.lv ?? mob.level ?? '?')}${maps.length ? ` ・ 出沒：${esc(maps.join('、'))}` : ''}</p><div class="wiki-meta">${stats.map(stat => `<span>${esc(stat)}</span>`).join('')}${mob.boss ? '<span>首領</span>' : ''}</div>${dropPreview ? `<p class="wiki-drop-preview">掉落：${esc(dropPreview)}${drops.length > 5 ? '…' : ''}</p>` : ''}</div></article>`;
    }).join('')}</div>` : '<p class="muted">找不到符合的怪物。</p>';
    renderPagination(rows.length, totalPages);
  }

  function renderDrops(term) {
    const drops = GameSiteData.getDrops();
    const rows = Object.entries(drops).filter(([mob, entries]) => {
      if (mob.toLowerCase().includes(term)) return true;
      return (entries || []).some(([id]) => `${id} ${nameOf(GameSiteData.itemById(id))}`.toLowerCase().includes(term));
    });
    const { totalPages, visible, start } = pagedRows(rows);
    count.textContent = rows.length ? `第 ${start + 1}～${start + visible.length} 筆／共 ${rows.length} 筆怪物掉落` : '找不到符合的掉落資料';
    content.innerHTML = visible.map(([mob, entries]) => {
      const sourceMob = GameSiteData.getMobs().find(candidate => (candidate.name || candidate.n) === mob);
      const maps = sourceMob ? GameSiteData.mapsForMob(sourceMob) : [];
      return `<article class="drop-mob"><h2>${esc(mob)}${maps.length ? `<small>出沒：${esc(maps.join('、'))}</small>` : ''}</h2><div class="drop-list">${(entries || []).map(([id, rate]) => { const item = GameSiteData.itemById(id); return `<span>${esc(nameOf(item) || id)} <em>${esc(rate)}%</em></span>`; }).join('')}</div></article>`;
    }).join('') || '<p class="muted">找不到符合的掉落資料。</p>';
    renderPagination(rows.length, totalPages);
  }

  function renderEnchant() {
    count.textContent = '強化規則請以遊戲內最新說明為準';
    content.innerHTML = `<div class="enchant-grid"><article class="enchant-card"><h2>武器強化</h2><ul><li>武器可在遊戲內進行強化。</li><li>實際成功、失敗與限制以物品與遊戲內系統提示為準。</li></ul></article><article class="enchant-card"><h2>防具強化</h2><ul><li>防具強化影響裝備效果。</li><li>不同裝備的可強化條件請查看遊戲內說明。</li></ul></article><article class="enchant-card"><h2>飾品強化</h2><ul><li>飾品同樣可依遊戲現行設定強化。</li><li>請先確認物品描述與系統提示再操作。</li></ul></article></div>`;
    pagination.innerHTML = '';
  }

  function render({ scrollList = false } = {}) {
    const term = String(search.value || '').trim().toLowerCase();
    document.querySelectorAll('[data-tab]').forEach(btn => btn.classList.toggle('active', btn.dataset.tab === active));
    if (active === 'items') renderItems(term);
    else if (active === 'monsters') renderMobs(term);
    else if (active === 'drops') renderDrops(term);
    else renderEnchant();
    if (scrollList) content.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  document.querySelectorAll('[data-tab]').forEach(btn => btn.addEventListener('click', () => {
    active = btn.dataset.tab;
    page = 1;
    search.value = '';
    history.replaceState(null, '', `?tab=${encodeURIComponent(active)}`);
    render({ scrollList: true });
  }));
  search.addEventListener('input', () => { page = 1; render(); });
  pagination.addEventListener('click', event => {
    const button = event.target.closest('[data-page]');
    if (!button || button.disabled) return;
    page = Number(button.dataset.page) || 1;
    render({ scrollList: true });
  });
  render();
})();
