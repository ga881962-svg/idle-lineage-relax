/* 玩家交易所：獨立全螢幕介面，使用贊助鑽石交易。 */
(function () {
  'use strict';
  var PANEL_ID = 'player-exchange-panel';
  var LISTING_FEE = 100000;
  var modal = null;

  function esc(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (ch) {
      return { '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[ch];
    });
  }
  function client() { return typeof window.onlineSupabase === 'function' ? window.onlineSupabase() : null; }
  function owned() { return typeof player !== 'undefined' && player && player.cloudCharacterId; }
  function sessionToken() { return typeof window.onlineCloudSessionToken === 'function' ? window.onlineCloudSessionToken() : ''; }
  function requestId() { return typeof window.onlineCloudRequestId === 'function' ? window.onlineCloudRequestId() : (window.crypto && crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + '-' + Math.random()); }
  function itemName(item) {
    // DB 是全域 const，不一定會掛在 window；原本檢查 window.DB 會退回顯示 wpn_xxx / arm_xxx 內部代號。
    if (typeof item === 'string') {
      try { item = JSON.parse(item); } catch (ignore) { item = { id:item }; }
    }
    var defs = (typeof DB !== 'undefined' && DB && DB.items) ? DB.items : ((window.DB && window.DB.items) || {});
    var def = defs[item && item.id];
    var name = def && def.n ? def.n : (item && item.id ? item.id : '未知物品');
    var enchant = Number(item && item.en) || 0;
    var count = Number(item && (item.cnt || item.count)) || 1;
    return (enchant ? '+' + enchant + ' ' : '') + name + (count > 1 ? ' ×' + count : '');
  }
  function setRevision(value) {
    if (typeof window.onlineCloudCheckpointRevision === 'function') window.onlineCloudCheckpointRevision(value);
  }
  function refreshLocal() {
    try { if (typeof updateUI === 'function') updateUI(); } catch (ignore) {}
    try { if (typeof saveGame === 'function') saveGame(); } catch (ignore) {}
  }
  function note(text, bad) {
    var el = document.getElementById('player-exchange-note');
    if (!el) return;
    if (/player_market_|schema cache|Could not find the function/i.test(String(text || ''))) {
      text = '交易所雲端資料正在同步，請稍後重新開啟。';
    }
    el.className = 'px-note ' + (bad ? 'is-error' : 'is-ok');
    el.textContent = text || '';
  }
  function marketMessage(error, fallback) {
    var raw = String(error && error.message ? error.message : error || '');
    if (/player_market_|schema cache|Could not find the function/i.test(raw)) {
      return '交易所雲端資料正在同步，請稍後重新開啟。';
    }
    return fallback || '交易所暫時無法使用，請稍後再試。';
  }
  function remaining(expiresAt) {
    var ms = new Date(expiresAt).getTime() - Date.now();
    if (!Number.isFinite(ms) || ms <= 0) return '即將到期';
    var hours = Math.ceil(ms / 3600000);
    return hours >= 24 ? '剩餘 ' + Math.ceil(hours / 24) + ' 天' : '剩餘 ' + hours + ' 小時';
  }
  function listingCard(row, mine) {
    return '<article class="px-listing">'
      + '<div class="px-item-icon">📦</div>'
      + '<div class="px-item-main"><strong>' + esc(itemName(row.item)) + '</strong>'
      + '<span>來自 S1　·　' + esc(remaining(row.expires_at)) + '</span></div>'
      + '<div class="px-price">💎 ' + Number(row.price_diamonds || 0).toLocaleString() + '</div>'
      + (mine
        ? '<button class="px-button px-cancel" onclick="playerExchangeCancel(\'' + row.id + '\')">取消上架</button>'
        : '<button class="px-button px-buy" onclick="playerExchangeBuy(\'' + row.id + '\')">購買</button>')
      + '</article>';
  }
  async function load() {
    var c = client();
    if (!c || !owned()) { note('請先登入並進入角色存檔，才能使用交易所。', true); return; }
    var token = sessionToken();
    if (!token) { note('安全連線尚未建立，請重新登入。', true); return; }
    var results = await Promise.all([
      c.rpc('secure_market_browse', { p_session_token:token }),
      c.rpc('secure_market_wallet', { p_session_token:token })
    ]);
    var listings = results[0], wallet = results[1];
    if (listings.error) { note(listings.error.message || '交易所讀取失敗。', true); return; }
    var balance = wallet.error ? 0 : Number(wallet.data || 0);
    var balanceEl = document.getElementById('player-exchange-balance');
    if (balanceEl) balanceEl.textContent = balance.toLocaleString();
    var list = document.getElementById('player-exchange-list');
    if (!list) return;
    var ownIds = window.playerExchangeOwnListings || {};
    list.innerHTML = (listings.data || []).length
      ? listings.data.map(function (row) { return listingCard(row, !!row.is_own || !!ownIds[row.id]); }).join('')
      : '<div class="px-empty">目前沒有玩家上架物品。</div>';
  }
  function createModal() {
    var style = document.createElement('style');
    style.id = 'player-exchange-style';
    style.textContent = [
      '#player-exchange-panel{position:fixed!important;inset:0!important;z-index:1000000!important;display:block!important;background:rgba(2,6,23,.94)!important;color:#e5edf9!important;font-family:"Microsoft JhengHei",Arial,sans-serif!important;overflow-y:auto!important}#player-exchange-panel.hidden{display:none!important}',
      '#player-exchange-panel *{box-sizing:border-box!important}',
      '.px-window{width:min(920px,calc(100vw - 32px))!important;margin:26px auto!important;padding:0 0 28px!important;border:1px solid #d1a53a!important;border-radius:16px!important;background:#0d1530!important;box-shadow:0 22px 70px #000!important;overflow:hidden!important}',
      '.px-head{display:flex!important;align-items:center!important;justify-content:space-between!important;padding:22px 26px!important;background:linear-gradient(135deg,#16244a,#0c1328)!important;border-bottom:1px solid #36527c!important}.px-title{margin:0!important;color:#f8dc5c!important;font-size:26px!important;font-weight:800!important}.px-sub{margin:7px 0 0!important;color:#a9bddb!important;font-size:14px!important}.px-close{border:0!important;background:transparent!important;color:#c6d5e9!important;font-size:36px!important;line-height:1!important;cursor:pointer!important}',
      '.px-body{padding:26px!important}.px-wallet{padding:20px 22px!important;border:1px solid #c7952e!important;border-radius:14px!important;background:#17132f!important;color:#cad7ed!important;font-size:16px!important}.px-wallet b{color:#ffe000!important;font-size:28px!important}.px-tabs{display:grid!important;grid-template-columns:repeat(3,minmax(0,1fr))!important;gap:10px!important;margin:18px 0!important}.px-tab{min-height:48px!important;border:1px solid #d3a53a!important;border-radius:11px!important;background:#11152d!important;color:#f2e2a5!important;font-size:16px!important;font-weight:700!important}.px-tab.is-active{background:#ffdc00!important;color:#17120a!important}',
      '.px-listing-form{display:grid!important;grid-template-columns:minmax(0,1fr) 150px 110px!important;gap:10px!important;padding:16px!important;border:1px solid #415475!important;border-radius:12px!important;background:#111a33!important}.px-input{min-width:0!important;height:46px!important;border:1px solid #657899!important;border-radius:8px!important;background:#050a19!important;color:#f1f5ff!important;padding:0 12px!important;font-size:16px!important}.px-button{min-height:42px!important;border:1px solid #e6b83e!important;border-radius:8px!important;padding:0 16px!important;font-size:16px!important;font-weight:800!important;cursor:pointer!important}.px-list{margin-top:14px!important}.px-listing{display:grid!important;grid-template-columns:54px minmax(0,1fr) 112px 92px!important;align-items:center!important;gap:14px!important;margin-top:10px!important;padding:16px!important;border:1px solid #3a3c76!important;border-radius:12px!important;background:#080c25!important}.px-item-icon{width:50px!important;height:50px!important;display:grid!important;place-items:center!important;border:1px solid #2d3b68!important;border-radius:8px!important;font-size:25px!important}.px-item-main{min-width:0!important;display:grid!important;gap:7px!important}.px-item-main strong{overflow:hidden!important;text-overflow:ellipsis!important;white-space:nowrap!important;color:#f8f1ff!important;font-size:18px!important}.px-item-main span{color:#91a9d1!important;font-size:14px!important}.px-price{color:#62dcff!important;font-size:17px!important;font-weight:800!important;text-align:right!important}.px-buy{background:#ffdc00!important;color:#211905!important}.px-cancel{background:#334155!important;color:#e7edf9!important;border-color:#64748b!important}.px-list-button{background:#ffd813!important;color:#211905!important}.px-note{min-height:24px!important;margin-top:10px!important;font-size:15px!important}.px-note.is-ok{color:#5cf0ae!important}.px-note.is-error{color:#ff8f99!important}.px-empty{padding:45px 12px!important;color:#a8b6cf!important;text-align:center!important;font-size:16px!important}',
      '@media(max-width:700px){#player-exchange-panel{overflow:hidden!important;padding:env(safe-area-inset-top,0) 0 env(safe-area-inset-bottom,0)!important}.px-window{width:calc(100vw - 16px)!important;height:calc(100dvh - 16px - env(safe-area-inset-top,0) - env(safe-area-inset-bottom,0))!important;max-height:none!important;margin:8px auto!important;display:flex!important;flex-direction:column!important;padding:0!important;border-radius:12px!important}.px-head{position:sticky!important;top:0!important;z-index:2!important;flex:0 0 auto!important;padding:13px 14px!important}.px-title{font-size:20px!important}.px-sub{font-size:12px!important}.px-close{min-width:44px!important;min-height:44px!important;font-size:30px!important}.px-body{flex:1 1 auto!important;min-height:0!important;overflow-y:auto!important;-webkit-overflow-scrolling:touch!important;padding:12px!important;padding-bottom:max(16px,env(safe-area-inset-bottom,0))!important}.px-wallet{padding:12px!important;font-size:14px!important}.px-wallet b{font-size:22px!important}.px-wallet span{display:block!important;margin-top:5px!important}.px-tabs{grid-template-columns:repeat(3,minmax(0,1fr))!important;gap:6px!important;margin:12px 0!important}.px-tab{min-height:44px!important;padding:5px!important;font-size:13px!important}.px-listing-form{grid-template-columns:1fr!important;padding:10px!important}.px-input,.px-button{min-height:46px!important;font-size:16px!important}.px-listing{grid-template-columns:42px minmax(0,1fr) 78px!important;gap:8px!important;margin-top:8px!important;padding:11px!important}.px-listing .px-button{grid-column:2 / 4!important}.px-item-icon{width:42px!important;height:42px!important}.px-price{font-size:14px!important}.px-item-main strong{font-size:15px!important}.px-item-main span{font-size:12px!important}.px-button,.px-tab,.px-close{touch-action:manipulation!important}}'
    ].join('');
    style.textContent += '#player-exchange-close{display:none!important}@media(max-width:700px){#player-exchange-close{position:fixed!important;display:flex!important;align-items:center!important;justify-content:center!important;right:14px!important;top:calc(14px + env(safe-area-inset-top,0px))!important;z-index:1000005!important;width:50px!important;height:50px!important;border:2px solid #94a3b8!important;border-radius:14px!important;background:#1e293b!important;color:#fff!important;font-size:34px!important;line-height:1!important;box-shadow:0 6px 20px rgba(0,0,0,.7)!important;touch-action:manipulation!important;pointer-events:auto!important}}';
    document.head.appendChild(style);
    modal = document.createElement('div');
    modal.id = PANEL_ID;
    modal.innerHTML = '<section class="px-window" role="dialog" aria-modal="true" aria-label="玩家交易所">'
      + '<header class="px-head"><div><h2 class="px-title">💎 玩家交易所</h2><p class="px-sub">玩家自由上架，以贊助鑽石交易；賣家匿名顯示為 S1。</p></div><button class="px-close" onclick="closePlayerExchange()" aria-label="關閉">×</button></header>'
      + '<main class="px-body"><div class="px-wallet">💎 你的贊助鑽石：<b id="player-exchange-balance">0</b><span>　上架費 100,000 金幣・期限 7 天・逾期自動退回原角色背包</span></div>'
      + '<div class="px-tabs"><button class="px-tab is-active" type="button">🛒 瀏覽購買</button><button class="px-tab" type="button" onclick="document.getElementById(\'player-exchange-item\').focus()">📤 我要上架</button><button class="px-tab" type="button" onclick="playerExchangeRefresh()">📦 我的上架</button></div>'
      + '<div class="px-listing-form"><select id="player-exchange-item" class="px-input"></select><input id="player-exchange-price" class="px-input" type="number" min="1" max="999999" placeholder="鑽石價格"><button class="px-button px-list-button" type="button" onclick="playerExchangeList()">上架</button></div>'
      + '<div id="player-exchange-note" class="px-note"></div><div id="player-exchange-list" class="px-list"></div></main></section><button id="player-exchange-close" type="button" aria-label="關閉交易所">×</button>';
    document.body.appendChild(modal);
    modal.addEventListener('pointerup', function (event) {
      var close = event.target && event.target.closest ? event.target.closest('.px-close, #player-exchange-close') : null;
      if (!close) return;
      event.preventDefault(); event.stopPropagation(); window.closePlayerExchange();
    }, true);
    modal.addEventListener('click', function (event) {
      var close = event.target && event.target.closest ? event.target.closest('.px-close, #player-exchange-close') : null;
      if (!close) return;
      event.preventDefault(); event.stopPropagation(); window.closePlayerExchange();
    }, true);
  }
  function show() {
    if (!modal) createModal();
    modal.classList.remove('hidden');
    var select = document.getElementById('player-exchange-item');
    var inventory = (typeof player !== 'undefined' && Array.isArray(player.inv)) ? player.inv : [];
    var allowed = inventory.filter(function (item) { return item && item.id && item.uid; });
    select.innerHTML = allowed.length ? allowed.map(function (item) {
      return '<option value="' + esc(item.uid) + '">' + esc(itemName(item)) + '</option>';
    }).join('') : '<option value="">沒有可上架的物品</option>';
    load().catch(function (error) { note(error.message || '交易所讀取失敗。', true); });
  }
  async function list() {
    var c = client();
    var select = document.getElementById('player-exchange-item');
    var priceInput = document.getElementById('player-exchange-price');
    var uid = select && select.value;
    var price = Number(priceInput && priceInput.value);
    if (!c || !owned()) return note('請先登入並進入角色存檔。', true);
    if (!uid || !Number.isInteger(price) || price < 1 || price > 999999) return note('請輸入 1 至 999,999 的鑽石價格。', true);
    if (Number(player.gold || 0) < LISTING_FEE) return note('金幣不足；每次上架需要 100,000 金幣。', true);
    var token = sessionToken();
    if (!token) return note('安全連線尚未建立，請重新登入。', true);
    var result = await c.rpc('secure_market_list', { p_session_token:token, p_character_id:player.cloudCharacterId, p_item_uid:uid, p_price:price, p_request_id:requestId() });
    if (result.error) return note(result.error.message || '上架失敗。', true);
    player.inv = (player.inv || []).filter(function (item) { return item.uid !== uid; });
    player.gold = Math.max(0, Number(player.gold || 0) - LISTING_FEE);
    window.playerExchangeOwnListings = window.playerExchangeOwnListings || {};
    if (result.data && result.data.listing_id) window.playerExchangeOwnListings[result.data.listing_id] = true;
    setRevision(result.data && result.data.revision); refreshLocal();
    note('上架成功：已扣除 100,000 金幣，7 天內未售出會自動退回背包。');
    load();
  }
  async function buy(id) {
    if (!confirm('確定使用贊助鑽石購買此物品嗎？')) return;
    var c = client(); if (!c || !owned()) return note('請先登入並進入角色存檔。', true);
    var token = sessionToken();
    if (!token) return note('安全連線尚未建立，請重新登入。', true);
    var result = await c.rpc('secure_market_buy', { p_session_token:token, p_character_id:player.cloudCharacterId, p_listing_id:id, p_request_id:requestId() });
    if (result.error) return note(result.error.message || '購買失敗。', true);
    if (result.data && result.data.item) { player.inv = player.inv || []; player.inv.push(result.data.item); }
    setRevision(result.data && result.data.revision); refreshLocal(); note('購買成功，物品已放入背包。'); load();
  }
  async function cancel(id) {
    var c = client(); if (!c || !owned()) return note('請先登入並進入角色存檔。', true);
    var token = sessionToken();
    if (!token) return note('安全連線尚未建立，請重新登入。', true);
    var result = await c.rpc('secure_market_cancel', { p_session_token:token, p_character_id:player.cloudCharacterId, p_listing_id:id, p_request_id:requestId() });
    if (result.error) return note(result.error.message || '取消上架失敗。', true);
    if (result.data && result.data.item) { player.inv = player.inv || []; player.inv.push(result.data.item); }
    if (window.playerExchangeOwnListings) delete window.playerExchangeOwnListings[id];
    setRevision(result.data && result.data.revision); refreshLocal(); note('已取消上架，物品已退回背包。'); load();
  }
  window.openPlayerExchange = show;
  window.closePlayerExchange = function () {
    var panel = modal || document.getElementById(PANEL_ID);
    if (panel) { panel.classList.add('hidden'); panel.setAttribute('aria-hidden', 'true'); }
  };
  window.playerExchangeRefresh = function () { load().catch(function (error) { note(error.message || '交易所讀取失敗。', true); }); };
  window.playerExchangeList = function () { list().catch(function (error) { note(error.message || '上架失敗。', true); }); };
  window.playerExchangeBuy = function (id) { buy(id).catch(function (error) { note(error.message || '購買失敗。', true); }); };
  window.playerExchangeCancel = function (id) { cancel(id).catch(function (error) { note(error.message || '取消上架失敗。', true); }); };
  document.addEventListener('DOMContentLoaded', function () {
    var blackMarket = document.getElementById('btn-pandora-shortcut');
    if (blackMarket && !document.getElementById('btn-player-exchange')) {
      blackMarket.insertAdjacentHTML('afterend', '<button onclick="openPlayerExchange()" id="btn-player-exchange" class="bg-cyan-950 hover:bg-cyan-900 px-3 py-1 text-cyan-100 font-bold border border-cyan-600 rounded text-sm shadow-md whitespace-nowrap min-w-[4.5rem] text-center" title="玩家自由上架，以贊助鑽石交易">交易所</button>');
    }
  });
})();
