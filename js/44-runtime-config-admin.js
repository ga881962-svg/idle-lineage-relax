/* Minimal GM-only editor for the existing runtime.config catalog. */
(function () {
  'use strict';
  var buttonId = 'runtime-config-admin-open';
  function allowed() { return typeof window.onlineCloudGmAllowed === 'function' && window.onlineCloudGmAllowed(); }
  function api(action, payload) {
    if (typeof window.onlineRuntimeConfigAdmin !== 'function') return Promise.reject(new Error('管理連線尚未就緒。'));
    return window.onlineRuntimeConfigAdmin(action, payload || {});
  }
  function esc(value) { return String(value == null ? '' : value).replace(/[&<>\"']/g, function (char) { return ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#039;' })[char]; }); }
  function close() { var el = document.getElementById('runtime-config-admin-modal'); if (el) el.remove(); }
  function number(id) { return Number(document.getElementById(id).value); }
  function updateForm(data) {
    var config = data.config || {};
    document.getElementById('runtime-config-version').value = String(data.version || '');
    document.getElementById('runtime-monster-scale').value = config.monster_scale;
    document.getElementById('runtime-boss-scale').value = config.boss_scale;
    document.getElementById('runtime-player-scale').value = config.player_scale;
    document.getElementById('runtime-mob-fps').value = config.mob_animation_fps;
    document.getElementById('runtime-black-market').checked = config.ui_entry_visibility && config.ui_entry_visibility.black_market !== false;
    document.getElementById('runtime-leaderboard').checked = config.ui_entry_visibility && config.ui_entry_visibility.leaderboard !== false;
    document.getElementById('runtime-config-result').textContent = '目前版本 ' + data.version + '；最後更新 ' + (data.generatedAt || '—');
  }
  async function load() {
    var result = document.getElementById('runtime-config-result'); result.textContent = '讀取中…';
    try { updateForm(await api('runtime.config.read')); } catch (error) { result.textContent = '讀取失敗：' + esc(error.message || error); }
  }
  async function save() {
    var result = document.getElementById('runtime-config-result');
    var payload = { version:Number(document.getElementById('runtime-config-version').value), config:{
      monster_scale:number('runtime-monster-scale'), boss_scale:number('runtime-boss-scale'), player_scale:number('runtime-player-scale'), mob_animation_fps:number('runtime-mob-fps'),
      ui_entry_visibility:{ black_market:document.getElementById('runtime-black-market').checked, leaderboard:document.getElementById('runtime-leaderboard').checked }
    }};
    result.textContent = '儲存中…';
    try { updateForm(await api('runtime.config.update', payload)); result.textContent += '　已儲存；玩家重新整理／重新登入後生效。'; }
    catch (error) { result.textContent = '儲存失敗：' + esc(error.message || error); }
  }
  function open() {
    if (!allowed()) return;
    close();
    var el = document.createElement('div'); el.id = 'runtime-config-admin-modal';
    el.style.cssText = 'position:fixed;inset:0;z-index:210000;display:grid;place-items:center;padding:16px;background:rgba(2,6,23,.82);font-family:Arial,"Microsoft JhengHei",sans-serif';
    el.innerHTML = '<section style="width:min(520px,100%);max-height:calc(100dvh - 32px);overflow:auto;padding:22px;border:1px solid #d6a92a;border-radius:14px;background:#10182b;color:#edf5ff;box-shadow:0 22px 70px #000">'
      + '<header style="display:flex;justify-content:space-between;align-items:center;gap:12px"><h2 style="margin:0;color:#ffdf49">營運設定</h2><button type="button" id="runtime-config-close">關閉</button></header>'
      + '<p style="color:#b8c9e5">僅調整視覺與入口；儲存後玩家重新登入或重新整理才會讀到新值。</p>'
      + '<input id="runtime-config-version" type="hidden"><div style="display:grid;grid-template-columns:1fr 120px;gap:12px;align-items:center">'
      + '<label>怪物大小</label><input id="runtime-monster-scale" type="number" min="0.5" max="2" step="0.05">'
      + '<label>Boss 大小</label><input id="runtime-boss-scale" type="number" min="0.5" max="2" step="0.05">'
      + '<label>主角大小</label><input id="runtime-player-scale" type="number" min="0.7" max="1.4" step="0.05">'
      + '<label>怪物動畫 FPS</label><input id="runtime-mob-fps" type="number" min="4" max="12" step="1">'
      + '<label>黑市入口</label><input id="runtime-black-market" type="checkbox">'
      + '<label>排行榜入口</label><input id="runtime-leaderboard" type="checkbox">'
      + '</div><p id="runtime-config-result" style="min-height:24px;color:#b8c9e5"></p><footer style="display:flex;gap:10px;justify-content:flex-end"><button type="button" id="runtime-config-reload">重新載入</button><button type="button" id="runtime-config-save" style="font-weight:800">儲存設定</button></footer></section>';
    document.body.appendChild(el);
    document.getElementById('runtime-config-close').onclick = close;
    document.getElementById('runtime-config-reload').onclick = load;
    document.getElementById('runtime-config-save').onclick = save;
    load();
  }
  function install(visible) {
    var old = document.getElementById(buttonId); if (old) old.remove();
    if (!visible || !allowed()) return;
    var head = document.querySelector('#gm-panel .gm-head'); if (!head) return;
    var button = document.createElement('button'); button.id = buttonId; button.type = 'button'; button.textContent = '營運設定'; button.onclick = open; head.appendChild(button);
  }
  window.runtimeConfigAdminAccessChanged = install;
  document.addEventListener('DOMContentLoaded', function () { install(allowed()); });
})();
