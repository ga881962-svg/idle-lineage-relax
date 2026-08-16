/* Official-site adapter: reads the existing game configuration without duplicating it. */
(function () {
  'use strict';
  const ROOT = '../';
  const resolver = window.assetUrl || (path => path || '');
  const classVisuals = Object.freeze({
    royal: { hero: 'assets/ui/battle-hero-royal-v1.png', role: '王室統御' },
    knight: { hero: 'assets/ui/battle-hero-knight-v1.png', role: '近戰守護' },
    mage: { hero: 'assets/ui/battle-hero-mage-v1.png', role: '元素法術' },
    elf: { hero: 'assets/ui/battle-hero-elf-v1.png', role: '遠距支援' },
    dark: { hero: 'assets/ui/battle-hero-dark-v1.png', role: '迅捷暗襲' },
    illusionist: { hero: 'assets/ui/battle-hero-illusionist-v1.png', role: '幻覺術法' },
    illusion: { hero: 'assets/ui/battle-hero-illusionist-v1.png', role: '幻覺術法' },
    Dknight: { hero: 'assets/ui/battle-hero-dknight-v1.png', role: '龍力爆發' },
    dragon: { hero: 'assets/ui/battle-hero-dknight-v1.png', role: '龍力爆發' },
    warrior: { hero: 'assets/ui/battle-hero-warrior-v1.png', role: '重裝戰鬥' }
  });

  async function loadGameMarkup() {
    const response = await fetch(ROOT + 'index.html', { cache: 'no-store' });
    if (!response.ok) throw new Error('無法讀取遊戲職業設定。');
    return new DOMParser().parseFromString(await response.text(), 'text/html');
  }
  async function getClasses() {
    const doc = await loadGameMarkup();
    return [...doc.querySelectorAll('[onclick*="selectClassBase"]')].map((button, index) => {
      const image = button.querySelector('img');
      const match = (button.getAttribute('onclick') || '').match(/selectClassBase\(['"]([^'"]+)/);
      const id = match ? match[1] : `class-${index + 1}`;
      const visual = classVisuals[id] || {};
      return { id, name: button.getAttribute('title') || image?.alt || `職業 ${index + 1}`, image: image?.getAttribute('src') || '', hero: visual.hero || '', role: visual.role || '冒險職業' };
    }).filter(entry => entry.image || entry.name);
  }
  function gameDb() { return typeof DB !== 'undefined' ? DB : window.DB; }
  function gameDrops() { return typeof MOB_DROPS !== 'undefined' ? MOB_DROPS : window.MOB_DROPS; }
  function getItems() {
    const items = gameDb()?.items || {};
    return Array.isArray(items) ? items : Object.entries(items).map(([id, item]) => ({ ...(item || {}), id: item?.id || id }));
  }
  function getMobs() {
    const mobs = gameDb()?.mobs || {};
    return Object.entries(mobs)
      .map(([id, mob]) => mob && ({ ...mob, id: mob.id || id, name: mob.name || mob.n || '' }))
      .filter(mob => mob && !mob.trollPlayer);
  }
  function getDrops() { return gameDrops() || {}; }
  function getMaps() {
    // DB.maps is loaded by the same canonical data source as DB.mobs.  The
    // public site intentionally does not maintain a second monster/map list.
    return Object.entries(gameDb()?.maps || {}).map(([id, mobs]) => ({ id, mobs: Array.isArray(mobs) ? mobs : [] }));
  }
  function mobDropEntries(mob) {
    const drops = getDrops();
    const key = typeof mob === 'string' ? mob : (mob?.name || mob?.n || mob?.id || '');
    return (drops[key] || []).map(([itemId, rate]) => ({ itemId, rate: Number(rate), item: itemById(itemId) }));
  }
  function mapsForMob(mob) {
    const id = typeof mob === 'string' ? mob : mob?.id;
    return getMaps().filter(map => map.mobs.includes(id)).map(map => map.id);
  }
  function dropSourcesForItem(item) {
    const itemId = typeof item === 'string' ? item : item?.id;
    return Object.entries(getDrops()).flatMap(([mobName, entries]) => (entries || [])
      .filter(([id]) => id === itemId)
      .map(([, rate]) => ({ mobName, rate: Number(rate), mob: getMobs().find(candidate => (candidate.name || candidate.n) === mobName) })));
  }
  function itemById(id) { return gameDb()?.items?.[id] || getItems().find(item => item && (item.id === id || item.uid === id)); }
  function safeIconPath(folder, filename) {
    return `assets/icons/safe/${folder}/${encodeURIComponent(filename).replace(/%/g, '_')}`;
  }
  function itemImage(item) {
    const entry = typeof item === 'string' ? itemById(item) || { id: item } : item || {};
    const raw = entry.icon || entry.img || entry.image || '';
    const match = /^assets\/icons\/(weapons|armors|accessories|items|skills)\/(.+)$/.exec(raw);
    if (match) return image(safeIconPath(match[1], match[2]));
    if (raw) return image(raw);
    const folder = entry.type === 'wpn' ? 'weapons' : entry.type === 'arm' ? 'armors' : entry.type === 'acc' ? 'accessories' : 'items';
    return entry.n ? image(safeIconPath(folder, `${entry.n}.png`)) : '';
  }
  function mobImage(mob) {
    const raw = mob?.img || mob?.image || '';
    const match = /^assets\/icons\/monsters\/(.+)$/.exec(raw);
    if (match) return image(`assets/icons/monsters/safe/${encodeURIComponent(match[1]).replace(/%/g, '_')}`);
    if (raw) return image(raw);
    return mob?.n ? image(`assets/icons/monsters/safe/${encodeURIComponent(`${mob.n}.png`).replace(/%/g, '_')}`) : '';
  }
  function getFeaturedMobs(limit = 5) {
    return getMobs().filter(mob => mob.n && !mob.siegeEnemy && !mob.pledgeEnemy && !mob.wild).sort((a, b) => Number(Boolean(b.boss)) - Number(Boolean(a.boss)) || (Number(b.lv) || 0) - (Number(a.lv) || 0)).slice(0, limit);
  }
  function getFeaturedItems(limit = 5) {
    return getItems().filter(item => item && item.n && !item.hidden).filter(item => item.icon || item.img || item.image || item.n).slice(0, limit);
  }
  function image(path) { return path ? resolver(path) : ''; }
  function getVersion() { return window.GAME_VERSION || gameDb()?.version || gameDb()?.VERSION || '目前版本'; }
  window.GameSiteData = Object.freeze({ getClasses, getItems, getMobs, getDrops, getMaps, mobDropEntries, mapsForMob, dropSourcesForItem, itemById, itemImage, mobImage, getFeaturedMobs, getFeaturedItems, getVersion, image });
})();
