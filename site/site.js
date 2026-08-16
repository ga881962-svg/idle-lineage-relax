(function () {
  'use strict';
  const q = (selector, root = document) => root.querySelector(selector);
  const escapeHtml = value => String(value ?? '').replace(/[&<>'"]/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[char]));
  const image = path => window.GameSiteData?.image(path) || path || '';

  function setupNav() {
    const button = q('[data-nav-toggle]'), nav = q('[data-site-nav]');
    if (!button || !nav) return;
    button.addEventListener('click', () => { const open = !nav.classList.contains('open'); nav.classList.toggle('open', open); button.setAttribute('aria-expanded', String(open)); });
    nav.addEventListener('click', event => { if (event.target.matches('a')) { nav.classList.remove('open'); button.setAttribute('aria-expanded', 'false'); } });
  }
  function setupVisualBase() {
    const background = image('assets/background/background.png');
    if (background) document.documentElement.style.setProperty('--site-world-bg', `url("${background}")`);
  }
  async function loadNews(root = document) {
    const target = q('[data-news-list]', root); if (!target) return;
    try {
      const response = await fetch('content/news.json', { cache: 'no-store' }); if (!response.ok) throw new Error();
      const all = await response.json(), limit = Number(target.dataset.newsLimit || all.length);
      target.innerHTML = all.slice(0, limit).map(news => `<a class="news-item" href="news.html#${encodeURIComponent(news.id)}"><span class="news-type ${escapeHtml(news.typeKey)}">${escapeHtml(news.type)}</span><span><b>${escapeHtml(news.title)}</b><time>${escapeHtml(news.date)}</time></span></a>`).join('');
    } catch { target.innerHTML = '<p class="muted">公告暫時無法讀取，請稍後再試。</p>'; }
  }
  function heroCard(entry, index) {
    if (!entry.hero) return '';
    return `<figure class="hero-character hero-character-${index + 1}"><img src="${escapeHtml(image(entry.hero))}" alt="${escapeHtml(entry.name)}"><figcaption>${escapeHtml(entry.name)}</figcaption></figure>`;
  }
  function loadHero(classes) {
    const target = q('[data-hero-roster]'); if (!target) return;
    const preferred = ['knight', 'mage', 'Dknight', 'dragon', 'elf'];
    const heroes = preferred.map(id => classes.find(entry => entry.id === id)).filter(Boolean).slice(0, 3);
    target.innerHTML = heroes.map(heroCard).join('');
  }
  async function loadClasses(root = document) {
    const target = q('[data-class-grid]', root); if (!target || !window.GameSiteData) return [];
    try {
      const classes = await GameSiteData.getClasses();
      target.innerHTML = classes.map(entry => `<a class="class-card" href="classes.html#${encodeURIComponent(entry.id)}"><div class="class-card-art">${entry.hero ? `<img src="${escapeHtml(image(entry.hero))}" alt="${escapeHtml(entry.name)}">` : entry.image ? `<img src="${escapeHtml(image(entry.image))}" alt="${escapeHtml(entry.name)}">` : ''}</div><span class="class-card-copy"><b>${escapeHtml(entry.name)}</b><small>${escapeHtml(entry.role)}</small><em>查看職業 →</em></span></a>`).join('');
      loadHero(classes);
      return classes;
    } catch { target.innerHTML = '<p class="muted">職業資料暫時無法讀取。</p>'; return []; }
  }
  function entityCard(entry, kind) {
    const isMob = kind === 'mob';
    const title = entry.n || entry.name || entry.id || '未知資料';
    const source = isMob ? GameSiteData.mobImage(entry) : GameSiteData.itemImage(entry);
    const sub = isMob ? `Lv.${Number(entry.lv) || '?'}` : (entry.t ? String(entry.t) : '遊戲物品');
    return `<article class="world-entity ${isMob ? 'is-mob' : 'is-item'}"><div class="entity-art">${source ? `<img src="${escapeHtml(source)}" alt="${escapeHtml(title)}" loading="lazy" onerror="this.parentElement.parentElement.classList.add('is-fallback')">` : ''}<span aria-hidden="true">${isMob ? '✹' : '◆'}</span></div><div><b>${escapeHtml(title)}</b><small>${escapeHtml(sub)}</small></div></article>`;
  }
  function loadWorldPreview() {
    if (!window.GameSiteData) return;
    const mobTarget = q('[data-world-mobs]'), itemTarget = q('[data-world-items]');
    if (mobTarget) mobTarget.innerHTML = GameSiteData.getFeaturedMobs().map(entry => entityCard(entry, 'mob')).join('') || '<p class="muted">暫無怪物資料。</p>';
    if (itemTarget) itemTarget.innerHTML = GameSiteData.getFeaturedItems().map(entry => entityCard(entry, 'item')).join('') || '<p class="muted">暫無物品資料。</p>';
  }
  function decorateFeatures() {
    const art = { knight: 'assets/ui/battle-hero-knight-v1.png', mage: 'assets/ui/battle-hero-mage-v1.png', dragon: 'assets/ui/battle-hero-dknight-v1.png', dark: 'assets/ui/battle-hero-dark-v1.png', elf: 'assets/ui/battle-hero-elf-v1.png', illusion: 'assets/ui/battle-hero-illusionist-v1.png' };
    document.querySelectorAll('[data-feature-art]').forEach(card => {
      const target = q('.feature-visual', card), source = image(art[card.dataset.featureArt]);
      if (target && source) target.style.backgroundImage = `url("${source}")`;
    });
  }
  function loadVersion() {
    const version = window.GameSiteData?.getVersion?.() || '目前版本';
    document.querySelectorAll('[data-game-version]').forEach(node => { node.textContent = version; });
  }
  function setupReveal() {
    const entries = [...document.querySelectorAll('[data-reveal]')];
    if (!('IntersectionObserver' in window)) { entries.forEach(entry => entry.classList.add('is-visible')); return; }
    const observer = new IntersectionObserver(rows => rows.forEach(row => { if (row.isIntersecting) { row.target.classList.add('is-visible'); observer.unobserve(row.target); } }), { threshold: .12 });
    entries.forEach(entry => observer.observe(entry));
  }
  document.addEventListener('DOMContentLoaded', () => { setupNav(); setupVisualBase(); loadVersion(); decorateFeatures(); loadNews(); loadClasses(); loadWorldPreview(); setupReveal(); });
  window.SiteUi = Object.freeze({ loadNews, loadClasses, loadWorldPreview, escapeHtml });
})();
