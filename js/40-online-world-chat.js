/* 世界頻道：只接收在線期間的 Realtime Broadcast，不保存任何聊天文字。 */
(function () {
  'use strict';
  var MAX_MESSAGE_LENGTH = 120;
  var MAX_VISIBLE_MESSAGES = 100;
  var TOPIC = 'world:global';
  var channel = null;
  var subscribed = false;
  var observer = null;

  function esc(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (ch) {
      return { '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[ch];
    });
  }
  function logElement() { return document.getElementById('world-log'); }
  function clear() {
    var log = logElement();
    if (log) log.innerHTML = '';
    var pins = document.getElementById('sys-log-pins');
    if (pins) pins.innerHTML = '';
  }
  function append(message) {
    var log = logElement();
    if (!log || !message || !message.id) return;
    var id = String(message.id);
    if (log.querySelector('[data-online-world-id="' + id.replace(/"/g, '') + '"]')) return;
    var row = document.createElement('div');
    row.className = 'world-message';
    row.dataset.onlineWorldId = id;
    row.innerHTML = '<b class="text-cyan-300">[' + esc(message.name || '冒險者') + ']</b> ' + esc(message.content || '');
    log.appendChild(row);
    // Broadcast chat is session-ephemeral. Keep the visual buffer bounded so
    // a long-lived tab cannot become an accidental client-side chat archive.
    while (log.querySelectorAll('[data-online-world-id]').length > MAX_VISIBLE_MESSAGES) {
      var oldest = log.querySelector('[data-online-world-id]');
      if (!oldest) break;
      oldest.remove();
    }
    log.scrollTop = log.scrollHeight;
  }
  function removeChannel() {
    var c = typeof window.onlineSupabase === 'function' ? window.onlineSupabase() : null;
    if (channel && c && typeof c.removeChannel === 'function') c.removeChannel(channel);
    channel = null;
    subscribed = false;
  }
  function connect() {
    var c = typeof window.onlineSupabase === 'function' ? window.onlineSupabase() : null;
    if (!c || channel || !window.onlineCloudSessionToken || !window.onlineCloudSessionToken()) return;
    // Private topic + an RLS receive-only policy means browser code can listen,
    // but cannot impersonate a sender by broadcasting directly.
    channel = c.channel(TOPIC, { config: { private: true, broadcast: { self: true, ack: true } } });
    channel.on('broadcast', { event: 'world_message' }, function (payload) {
      append(payload && payload.payload);
    }).subscribe(function (status) {
      subscribed = status === 'SUBSCRIBED';
    });
  }
  function currentCharacter() {
    return typeof player !== 'undefined' && player && player.cloudCharacterId ? player.cloudCharacterId : '';
  }
  async function send() {
    var input = document.getElementById('world-input');
    var content = String(input && input.value || '').trim();
    if (!content) return;
    if (content.length > MAX_MESSAGE_LENGTH) return window.alert('世界頻道訊息最多 ' + MAX_MESSAGE_LENGTH + ' 個字。');
    if (!currentCharacter() || !window.onlineCloudSessionToken || !window.onlineCloudSessionToken()) {
      return window.alert('安全連線尚未建立，請重新登入。');
    }
    if (typeof window.onlineCloudApi !== 'function') return window.alert('聊天服務尚未準備完成，請稍後再試。');
    var button = document.getElementById('world-send');
    if (button) button.disabled = true;
    try {
      await window.onlineCloudApi({ action: 'world.send', characterId: currentCharacter(), content: content });
      input.value = '';
    } catch (error) {
      var text = String(error && error.message || error || '');
      if (/SESSION_REPLACED|SESSION_REQUIRED|SESSION_EXPIRED/i.test(text)) return;
      window.alert(/CHAT_COOLDOWN/i.test(text) ? '發言太快，請稍後再試。' : '訊息送出失敗，請稍後再試。');
    } finally {
      if (button) button.disabled = false;
    }
  }
  function install() {
    // The previous implementation read world_messages and subscribed to
    // Postgres changes.  Do neither: this log starts empty for every session.
    clear();
    connect();
    var log = logElement();
    if (log && !observer && typeof MutationObserver !== 'undefined') {
      // The old offline channel contains NPC message timers. Keep this log
      // exclusively for verified Broadcast messages without changing its
      // unrelated legacy implementation.
      observer = new MutationObserver(function (mutations) {
        mutations.forEach(function (mutation) {
          mutation.addedNodes.forEach(function (node) {
            if (node.nodeType === 1 && !node.dataset.onlineWorldId) node.remove();
          });
        });
      });
      observer.observe(log, { childList:true });
    }
    var input = document.getElementById('world-input');
    if (input && !input.dataset.onlineWorldBound) {
      input.dataset.onlineWorldBound = '1';
      input.addEventListener('keydown', function (event) {
        if (event.key === 'Enter' && !event.isComposing) { event.preventDefault(); send(); }
      });
    }
    var sendButton = document.getElementById('world-send');
    if (sendButton && !sendButton.dataset.onlineWorldBound) {
      sendButton.dataset.onlineWorldBound = '1';
      sendButton.addEventListener('click', send);
    }
  }
  window.onlineWorldChatReset = function () { clear(); removeChannel(); };
  window.onlineWorldChatConnect = function () { clear(); connect(); };
  // Existing legacy Enter-key handling calls this global dynamically. Replace
  // it so it follows the authenticated API path instead of spawning NPC text.
  window.worldChannelAsk = send;
  document.addEventListener('DOMContentLoaded', install);
})();
