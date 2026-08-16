/* 玩家交易所：一筆訂單整包交易；價格與數量一律由伺服器再驗證。 */
(function () {
  'use strict';
  var PANEL_ID = 'player-exchange-panel';
  var LISTING_FEE = 100000;
  var modal = null;
  var view = 'browse';

  function esc(value) { return String(value == null ? '' : value).replace(/[&<>"']/g, function (ch) { return { '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[ch]; }); }
  function client() { return typeof window.onlineSupabase === 'function' ? window.onlineSupabase() : null; }
  function owned() { return typeof player !== 'undefined' && player && player.cloudCharacterId; }
  function token() { return typeof window.onlineCloudSessionToken === 'function' ? window.onlineCloudSessionToken() : ''; }
  function requestId() { return typeof window.onlineCloudRequestId === 'function' ? window.onlineCloudRequestId() : (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random()); }
  function revision(value) { if (typeof window.onlineCloudCheckpointRevision === 'function') window.onlineCloudCheckpointRevision(value); }
  function refreshLocal() { try { if (typeof updateUI === 'function') updateUI(); } catch (_) {} try { if (typeof saveGame === 'function') saveGame(); } catch (_) {} }
  function applyCanonical(result) {
    if (!result || !result.state || !result.state.p || typeof player === 'undefined' || !player) throw new Error('MARKET_CANONICAL_STATE_MISSING');
    Object.keys(player).forEach(function (key) { delete player[key]; });
    Object.assign(player, result.state.p);
    revision(result.revision);
    refreshLocal();
  }
  function parseItem(value) { if (typeof value === 'string') { try { return JSON.parse(value); } catch (_) { return { id:value }; } } return value || {}; }
  function count(item) { item = parseItem(item); return Math.max(1, Math.floor(Number(item.cnt != null ? item.cnt : item.count) || 1)); }
  function itemName(item) {
    item = parseItem(item);
    var defs = typeof DB !== 'undefined' && DB && DB.items ? DB.items : ((window.DB && window.DB.items) || {});
    var def = defs[item.id] || {};
    return (Number(item.en) ? '+' + Number(item.en) + ' ' : '') + (def.n || item.n || item.name || item.id || '未知物品');
  }
  function itemIcon(item) {
    item = parseItem(item);
    var defs = typeof DB !== 'undefined' && DB && DB.items ? DB.items : ((window.DB && window.DB.items) || {});
    var def = defs[item.id] || {};
    var source = item.icon || item.img || def.icon || def.img || def.image || '';
    if (!source) return '<span aria-hidden="true">📦</span>';
    if (typeof window.assetUrl === 'function') source = window.assetUrl(source);
    return '<img src="' + esc(source) + '" alt="" onerror="this.replaceWith(document.createTextNode(\'📦\'))">';
  }
  function money(value) { return Math.max(0, Math.floor(Number(value) || 0)).toLocaleString(); }
  function left(expiresAt) {
    var ms = new Date(expiresAt).getTime() - Date.now(); if (!Number.isFinite(ms) || ms <= 0) return '即將到期';
    var h = Math.ceil(ms / 3600000); return h >= 24 ? '剩餘 ' + Math.ceil(h / 24) + ' 天' : '剩餘 ' + h + ' 小時';
  }
  function note(text, bad) { var el = document.getElementById('player-exchange-note'); if (el) { el.className = 'px-note ' + (bad ? 'is-error' : 'is-ok'); el.textContent = text || ''; } }
  function errorText(error, fallback) {
    var raw = String(error && error.message || error || '');
    if (/SESSION_REPLACED|SESSION_REQUIRED|SESSION_EXPIRED/i.test(raw)) return '安全連線已失效，請重新登入。';
    if (/schema cache|Could not find the function/i.test(raw)) return '交易所正在更新，請稍後重新開啟。';
    return fallback || '交易所暫時無法使用，請稍後再試。';
  }
  async function handleActionError(error) {
    if (/CHECKPOINT_CONFLICT/i.test(String(error && (error.message || error)))) {
      if (typeof window.onlineCloudRestoreCheckpoint === 'function') await window.onlineCloudRestoreCheckpoint();
      note('角色資料已由伺服器重新載入，請重新操作。', true);
      return true;
    }
    return false;
  }
  // 交易所診斷：僅在瀏覽器 Console 保留 RPC 原始錯誤，不顯示 session token 或角色資料。
  function reportRpcError(rpc, error, phase) {
    var diagnostic = {
      rpc: rpc,
      phase: phase || 'RPC response',
      code: error && error.code != null ? error.code : null,
      message: error && error.message ? error.message : String(error || ''),
      details: error && (error.details != null ? error.details : (error.detail != null ? error.detail : null)),
      hint: error && error.hint != null ? error.hint : null,
      context: error && error.context != null ? error.context : null,
      raw: error || null,
      at: new Date().toISOString()
    };
    try {
      window.__playerExchangeLastRpcError = diagnostic;
      console.error('[玩家交易所診斷] RPC 失敗', diagnostic);
    } catch (_) {}
  }
  function inventory() { return owned() && Array.isArray(player.inv) ? player.inv.filter(function (i) { return i && i.id && i.uid; }) : []; }
  function selected() { var uid = document.getElementById('player-exchange-item')?.value; return inventory().find(function (item) { return item.uid === uid; }) || null; }
  function qtyValue() { return Math.max(1, Math.floor(Number(document.getElementById('player-exchange-qty')?.value) || 1)); }
  function unitPrice() { return Math.max(0, Math.floor(Number(document.getElementById('player-exchange-price')?.value) || 0)); }
  function updateForm() {
    var item = selected(), held = item ? count(item) : 0, qty = Math.min(held || 1, qtyValue());
    var input = document.getElementById('player-exchange-qty'); if (input) { input.max = String(held || 1); input.value = String(qty); }
    var heldEl = document.getElementById('player-exchange-held'); if (heldEl) heldEl.textContent = '持有 ' + held;
    var totalEl = document.getElementById('player-exchange-total'); if (totalEl) totalEl.textContent = money(qty * unitPrice());
  }
  function listingCard(row, mine) {
    var quantity = Math.max(1, Number(row.quantity) || count(row.item));
    var unit = Math.max(0, Number(row.unit_price_diamonds != null ? row.unit_price_diamonds : row.price_diamonds) || 0);
    var total = Math.max(0, Number(row.price_diamonds) || quantity * unit);
    return '<article class="px-listing"><div class="px-item-icon">' + itemIcon(row.item) + '</div><div class="px-item-main"><strong>' + esc(itemName(row.item)) + ' ×' + quantity + '</strong><span>' + (mine ? '到期：' : '來自 S1・') + esc(left(row.expires_at)) + '</span></div><div class="px-price">💎 ' + money(unit) + '<small>／件・總計 ' + money(total) + '</small></div>' + (mine ? '<button class="px-button px-cancel" onclick="playerExchangeCancel(\'' + esc(row.id) + '\')">取消上架</button>' : '<button class="px-button px-buy" onclick="playerExchangeBuy(\'' + esc(row.id) + '\')">整包購買</button>') + '</article>';
  }
  async function load() {
    var c = client(); if (!c || !owned()) return note('請先登入並進入角色存檔，才能使用交易所。', true);
    if (!token()) return note('安全連線尚未建立，請重新登入。', true);
    // Expiry reclaim is a canonical, ledgered write action.  It is never
    // hidden inside a browse RPC (which used to call a legacy writer).
    var reclaim = await c.rpc('secure_market_reclaim', { p_session_token:token(), p_character_id:player.cloudCharacterId, p_request_id:requestId() });
    if (reclaim.error) { if (!await handleActionError(reclaim.error)) note(errorText(reclaim.error), true); return; }
    if (reclaim.data && Number(reclaim.data.reclaimed || 0) > 0) applyCanonical(reclaim.data);
    var calls = [c.rpc('secure_market_wallet', { p_session_token:token() })];
    calls.push(view === 'mine' ? c.rpc('secure_market_mine', { p_session_token:token(), p_character_id:player.cloudCharacterId }) : c.rpc('secure_market_browse_v2', { p_session_token:token(), p_character_id:player.cloudCharacterId }));
    var result = await Promise.all(calls), wallet = result[0], listings = result[1];
    if (wallet.error) return note(errorText(wallet.error), true);
    document.getElementById('player-exchange-balance').textContent = money(wallet.data || 0);
    if (listings.error) {
      reportRpcError(view === 'mine' ? 'secure_market_mine' : 'secure_market_browse_v2', listings.error);
      return note(errorText(listings.error), true);
    }
    var host = document.getElementById('player-exchange-list'); if (!host) return;
    var rows = listings.data || [];
    host.innerHTML = rows.length ? rows.map(function (row) { return listingCard(row, view === 'mine'); }).join('') : '<div class="px-empty">' + (view === 'mine' ? '你目前沒有上架中的商品。' : '目前沒有玩家上架物品。') + '</div>';
  }
  function setView(next) {
    view = next;
    document.querySelectorAll('#' + PANEL_ID + ' .px-tab').forEach(function (button) { button.classList.toggle('is-active', button.dataset.view === next); });
    var form = document.getElementById('player-exchange-form'); if (form) form.hidden = next !== 'list';
    note(''); updateForm(); load().catch(function (error) {
      reportRpcError(next === 'mine' ? 'secure_market_mine' : 'secure_market_browse_v2', error, 'request exception');
      note(errorText(error), true);
    });
  }
  function createModal() {
    var style = document.createElement('style'); style.id = 'player-exchange-style';
    style.textContent = '#player-exchange-panel{position:fixed!important;inset:0!important;z-index:1000000!important;background:rgba(2,6,23,.94)!important;color:#e5edf9!important;font-family:"Microsoft JhengHei",Arial,sans-serif!important;overflow:auto!important}#player-exchange-panel.hidden{display:none!important}#player-exchange-panel *{box-sizing:border-box!important}.px-window{width:min(920px,calc(100vw - 32px));margin:26px auto;border:1px solid #d1a53a;border-radius:16px;background:#0d1530;box-shadow:0 22px 70px #000;overflow:hidden}.px-head{display:flex;align-items:center;justify-content:space-between;padding:22px 26px;background:linear-gradient(135deg,#16244a,#0c1328);border-bottom:1px solid #36527c}.px-title{margin:0;color:#f8dc5c;font-size:26px}.px-sub{margin:7px 0 0;color:#a9bddb;font-size:14px}.px-close{border:0;background:transparent;color:#fff;font-size:36px;cursor:pointer}.px-body{padding:26px}.px-wallet,.px-listing-form{border:1px solid #c7952e;border-radius:14px;background:#17132f;padding:18px;color:#cad7ed}.px-wallet b{color:#ffe000;font-size:28px}.px-tabs{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin:18px 0}.px-tab,.px-button{min-height:46px;border:1px solid #d3a53a;border-radius:11px;background:#11152d;color:#f2e2a5;font-size:16px;font-weight:800;cursor:pointer}.px-tab.is-active,.px-list-button,.px-buy{background:#ffdc00;color:#17120a}.px-listing-form{display:grid;grid-template-columns:minmax(0,1fr) 112px 170px;gap:10px;align-items:center;border-color:#415475;background:#111a33}.px-input{width:100%;height:46px;border:1px solid #657899;border-radius:8px;background:#050a19;color:#f1f5ff;padding:0 12px;font-size:16px}.px-qty{display:flex;align-items:center;gap:6px}.px-qty button{width:36px;height:40px;border:1px solid #657899;border-radius:7px;background:#223252;color:#fff;font-size:21px}.px-qty input{width:48px;text-align:center;padding:0}.px-form-total{grid-column:1/-1;color:#c8d9f4;font-size:15px}.px-form-total b{color:#ffe000;font-size:20px}.px-list{margin-top:14px}.px-listing{display:grid;grid-template-columns:54px minmax(0,1fr) 150px 106px;align-items:center;gap:14px;margin-top:10px;padding:16px;border:1px solid #3a3c76;border-radius:12px;background:#080c25}.px-item-icon{width:50px;height:50px;display:grid;place-items:center;border:1px solid #2d3b68;border-radius:8px;font-size:25px;overflow:hidden}.px-item-icon img{max-width:100%;max-height:100%;object-fit:contain}.px-item-main{min-width:0;display:grid;gap:7px}.px-item-main strong{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#f8f1ff;font-size:18px}.px-item-main span{color:#91a9d1;font-size:14px}.px-price{color:#62dcff;font-size:17px;font-weight:800;text-align:right}.px-price small{display:block;color:#a9bddb;font-size:12px;margin-top:5px}.px-cancel{background:#334155;color:#e7edf9;border-color:#64748b}.px-note{min-height:24px;margin-top:10px}.px-note.is-ok{color:#5cf0ae}.px-note.is-error{color:#ff8f99}.px-empty{padding:45px 12px;color:#a8b6cf;text-align:center}@media(max-width:700px){#player-exchange-panel{overflow:hidden;padding:env(safe-area-inset-top,0) 0 env(safe-area-inset-bottom,0)}.px-window{width:calc(100vw - 16px);height:calc(100dvh - 16px);margin:8px auto;display:flex;flex-direction:column;border-radius:12px}.px-head{padding:13px 14px}.px-title{font-size:20px}.px-sub{font-size:12px}.px-close{min-width:48px;min-height:48px;font-size:32px}.px-body{flex:1;overflow:auto;padding:12px;-webkit-overflow-scrolling:touch}.px-wallet{padding:12px;font-size:14px}.px-wallet b{font-size:22px}.px-tabs{gap:6px;margin:12px 0}.px-tab{font-size:13px}.px-listing-form{grid-template-columns:1fr;padding:10px}.px-form-total{grid-column:auto}.px-listing{grid-template-columns:42px minmax(0,1fr) 82px;gap:8px;padding:11px}.px-listing .px-button{grid-column:2/4}.px-item-icon{width:42px;height:42px}.px-item-main strong{font-size:15px}.px-price{font-size:14px}.px-button,.px-tab,.px-close{touch-action:manipulation}}';
    document.head.appendChild(style);
    modal = document.createElement('div'); modal.id = PANEL_ID;
    modal.innerHTML = '<section class="px-window" role="dialog" aria-modal="true"><header class="px-head"><div><h2 class="px-title">💎 玩家交易所</h2><p class="px-sub">玩家自由上架，以贊助鑽石交易；賣家匿名顯示為 S1。</p></div><button class="px-close" type="button" onclick="closePlayerExchange()" aria-label="關閉">×</button></header><main class="px-body"><div class="px-wallet">💎 你的贊助鑽石：<b id="player-exchange-balance">0</b><span>　上架費 100,000 金幣・期限 7 天・逾期自動退回原角色背包</span></div><div class="px-tabs"><button class="px-tab" data-view="browse" type="button" onclick="playerExchangeView(\'browse\')">🛒 瀏覽購買</button><button class="px-tab" data-view="list" type="button" onclick="playerExchangeView(\'list\')">📤 我要上架</button><button class="px-tab" data-view="mine" type="button" onclick="playerExchangeView(\'mine\')">📦 我的上架</button></div><div id="player-exchange-form" class="px-listing-form" hidden><select id="player-exchange-item" class="px-input" onchange="playerExchangeFormChanged()"></select><div class="px-qty"><button type="button" onclick="playerExchangeAdjustQuantity(-1)">−</button><input id="player-exchange-qty" class="px-input" type="number" min="1" value="1" onchange="playerExchangeFormChanged()"><button type="button" onclick="playerExchangeAdjustQuantity(1)">+</button><span id="player-exchange-held"></span></div><input id="player-exchange-price" class="px-input" type="number" min="1" max="999999" placeholder="每件單價" oninput="playerExchangeFormChanged()"><div class="px-form-total">總價：💎 <b id="player-exchange-total">0</b></div><button class="px-button px-list-button" type="button" onclick="playerExchangeList()">上架</button></div><div id="player-exchange-note" class="px-note"></div><div id="player-exchange-list" class="px-list"></div></main></section>';
    document.body.appendChild(modal);
  }
  function show() {
    if (!modal) createModal(); modal.classList.remove('hidden');
    var select = document.getElementById('player-exchange-item'); var items = inventory();
    select.innerHTML = items.length ? items.map(function (item) { return '<option value="' + esc(item.uid) + '">' + esc(itemName(item)) + ' ×' + count(item) + '</option>'; }).join('') : '<option value="">沒有可上架的物品</option>';
    setView('browse');
  }
  async function list() {
    var c = client(), item = selected(), quantity = qtyValue(), price = unitPrice();
    if (!c || !owned()) return note('請先登入並進入角色存檔。', true);
    if (!item || quantity < 1 || quantity > count(item)) return note('上架數量不能超過實際持有數量。', true);
    if (!Number.isInteger(price) || price < 1 || price > 999999) return note('請輸入 1 至 999,999 的每件鑽石價格。', true);
    if (Number(player.gold || 0) < LISTING_FEE) return note('金幣不足；每次上架需要 100,000 金幣。', true);
    if (!token()) return note('安全連線尚未建立，請重新登入。', true);
    var result = await c.rpc('secure_market_list', { p_session_token:token(), p_character_id:player.cloudCharacterId, p_item_uid:item.uid, p_quantity:quantity, p_unit_price:price, p_request_id:requestId() });
    if (result.error) { if (!await handleActionError(result.error)) note(errorText(result.error), true); return; }
    applyCanonical(result.data); note('上架成功：已扣除 100,000 金幣，7 天內未售出會自動退回背包。'); setView('mine');
  }
  async function buy(id) {
    if (!confirm('確定以贊助鑽石整包購買這張訂單嗎？')) return;
    var c = client(); if (!c || !owned() || !token()) return note('安全連線尚未建立，請重新登入。', true);
    var result = await c.rpc('secure_market_buy', { p_session_token:token(), p_character_id:player.cloudCharacterId, p_listing_id:id, p_request_id:requestId() });
    if (result.error) { if (!await handleActionError(result.error)) note(errorText(result.error), true); return; }
    applyCanonical(result.data); note('購買成功，物品已放入背包。'); load();
  }
  async function cancel(id) {
    var c = client(); if (!c || !owned() || !token()) return note('安全連線尚未建立，請重新登入。', true);
    var result = await c.rpc('secure_market_cancel', { p_session_token:token(), p_character_id:player.cloudCharacterId, p_listing_id:id, p_request_id:requestId() });
    if (result.error) { if (!await handleActionError(result.error)) note(errorText(result.error), true); return; }
    applyCanonical(result.data); note('已取消上架，物品已退回背包。'); load();
  }
  window.openPlayerExchange = show;
  window.closePlayerExchange = function () { if (modal) modal.classList.add('hidden'); };
  window.playerExchangeView = setView;
  window.playerExchangeFormChanged = updateForm;
  window.playerExchangeAdjustQuantity = function (delta) { var input = document.getElementById('player-exchange-qty'), held = count(selected()); input.value = String(Math.max(1, Math.min(held, qtyValue() + Number(delta || 0)))); updateForm(); };
  window.playerExchangeList = function () { list().catch(function (error) { note(errorText(error), true); }); };
  window.playerExchangeBuy = function (id) { buy(id).catch(function (error) { note(errorText(error), true); }); };
  window.playerExchangeCancel = function (id) { cancel(id).catch(function (error) { note(errorText(error), true); }); };
  document.addEventListener('DOMContentLoaded', function () { var blackMarket = document.getElementById('btn-pandora-shortcut'); if (blackMarket && !document.getElementById('btn-player-exchange')) blackMarket.insertAdjacentHTML('afterend', '<button onclick="openPlayerExchange()" id="btn-player-exchange" class="bg-cyan-950 hover:bg-cyan-900 px-3 py-1 text-cyan-100 font-bold border border-cyan-600 rounded text-sm shadow-md whitespace-nowrap min-w-[4.5rem] text-center">交易所</button>'); });
})();
