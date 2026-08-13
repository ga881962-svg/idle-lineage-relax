(function () {
  'use strict';

  var panel = document.getElementById('data-panel');
  var buttons = Array.prototype.slice.call(document.querySelectorAll('[data-tab]'));
  var activeTab = new URLSearchParams(location.search).get('tab') || 'items';

  function esc(value) {
    return String(value == null ? '' : value).replace(/[&<>'"]/g, function (character) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[character];
    });
  }

  function format(value) {
    return Number(value || 0).toLocaleString('zh-TW');
  }

  function typeLabel(item) {
    var type = String(item.type || '');
    if (type === 'wpn') return '武器';
    if (type === 'arm') return '防具';
    if (type === 'acc') return '飾品';
    if (type === 'book') return '魔法書';
    return '道具';
  }

  function itemRows(query, type) {
    var all = Object.keys(DB.items || {}).map(function (id) {
      return Object.assign({ id: id }, DB.items[id]);
    });
    return all.filter(function (item) {
      var name = String(item.n || '').toLowerCase();
      return (!query || name.indexOf(query) !== -1 || item.id.toLowerCase().indexOf(query) !== -1) &&
        (!type || item.type === type);
    });
  }

  function renderItems(query, type) {
    var rows = itemRows(query, type);
    var cards = rows.slice(0, 160).map(function (item) {
      var detail = [];
      if (item.dmgS != null || item.dmgL != null) detail.push('傷害 ' + (item.dmgS || 0) + ' / ' + (item.dmgL || 0));
      if (item.ac != null) detail.push('防禦 -' + item.ac);
      if (item.safe != null) detail.push('安全強化 +' + item.safe);
      if (item.req) detail.push('需求 ' + item.req);
      return '<article class="wiki-entry"><h3>' + esc(item.n || item.id) + '</h3>' +
        '<p>' + esc(detail.join('｜') || item.d || '一般道具') + '</p>' +
        '<span class="tag">' + typeLabel(item) + '</span>' +
        (item.p ? '<span class="tag">售價 ' + format(item.p) + '</span>' : '') +
        '</article>';
    }).join('');

    panel.innerHTML = '<div class="wiki-toolbar"><input id="wiki-search" placeholder="搜尋物品名稱或 ID" value="' + esc(query) + '">' +
      '<select id="wiki-type"><option value="">全部類型</option><option value="wpn">武器</option><option value="arm">防具</option><option value="acc">飾品</option><option value="book">魔法書</option></select></div>' +
      '<p class="wiki-summary">找到 <b>' + format(rows.length) + '</b> 件物品。</p><div class="wiki-list">' + cards + '</div>' +
      (rows.length > 160 ? '<p class="wiki-summary">目前僅顯示前 160 筆，請輸入名稱或 ID 縮小範圍。</p>' : '');

    var input = document.getElementById('wiki-search');
    var select = document.getElementById('wiki-type');
    select.value = type || '';
    input.oninput = function () { renderItems(input.value.trim().toLowerCase(), select.value); };
    select.onchange = function () { renderItems(input.value.trim().toLowerCase(), select.value); };
  }

  function renderMonsters(query) {
    var all = Object.keys(DB.mobs || {}).map(function (id) {
      return Object.assign({ id: id }, DB.mobs[id]);
    }).filter(function (mob) {
      // 玩家 NPC 只保留給競技場內部使用，不是怪物圖鑑內容。
      return !mob.trollPlayer;
    });
    var rows = all.filter(function (mob) {
      var name = String(mob.n || '').toLowerCase();
      return !query || name.indexOf(query) !== -1 || mob.id.toLowerCase().indexOf(query) !== -1;
    }).sort(function (a, b) { return Number(a.lv || 0) - Number(b.lv || 0); });

    var cards = rows.slice(0, 160).map(function (mob) {
      return '<article class="wiki-entry"><h3>' + esc(mob.n || mob.id) + '</h3>' +
        '<p>Lv.' + format(mob.lv) + '｜HP ' + format(mob.hp) + '｜AC ' + format(mob.ac) + '｜MR ' + format(mob.mr) + '</p>' +
        '<span class="tag">經驗 ' + format(mob.exp) + '</span>' +
        (mob.boss ? '<span class="tag">頭目</span>' : '') +
        '</article>';
    }).join('');

    panel.innerHTML = '<div class="wiki-toolbar"><input id="wiki-search" placeholder="搜尋怪物名稱或 ID" value="' + esc(query) + '"></div>' +
      '<p class="wiki-summary">找到 <b>' + format(rows.length) + '</b> 隻怪物。</p><div class="wiki-list">' + cards + '</div>' +
      (rows.length > 160 ? '<p class="wiki-summary">目前僅顯示前 160 筆，請輸入名稱或 ID 縮小範圍。</p>' : '');
    document.getElementById('wiki-search').oninput = function () { renderMonsters(this.value.trim().toLowerCase()); };
  }

  function renderEnchant() {
    panel.innerHTML = '<div class="rule-grid">' +
      '<article class="rule"><h2>武器強化</h2><p>武器最高可強化至 <b>+20</b>。強化會依照目前等級與卷軸類型判定成功或失敗；失敗可能降低強化值或使裝備損壞。</p></article>' +
      '<article class="rule"><h2>防具強化</h2><p>防具最高可強化至 <b>+15</b>。強化提升額外防禦（AC），超過安全強化後失敗會有風險。</p></article>' +
      '<article class="rule"><h2>飾品強化</h2><p>飾品最高可強化至 <b>+5</b>。可提高飾品附加能力，失敗機率與失敗效果會依飾品設定而異。</p></article></div>' +
      '<p class="wiki-summary" style="margin-top:20px">實際機率以遊戲內的強化介面與道具說明為準。</p>';
  }

  function render(tab) {
    activeTab = tab;
    buttons.forEach(function (button) { button.classList.toggle('active', button.dataset.tab === tab); });
    if (tab === 'monsters') renderMonsters('');
    else if (tab === 'enchant') renderEnchant();
    else renderItems('', '');
  }

  buttons.forEach(function (button) {
    button.addEventListener('click', function () {
      history.replaceState(null, '', '?tab=' + button.dataset.tab);
      render(button.dataset.tab);
    });
  });

  if (typeof DB === 'undefined') {
    panel.innerHTML = '<p class="wiki-summary">圖鑑資料尚未載入，請重新整理頁面後再試一次。</p>';
    return;
  }
  render(activeTab);
})();
