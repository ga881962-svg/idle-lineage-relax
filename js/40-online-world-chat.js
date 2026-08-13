/* 雲端世界頻道：停用所有 NPC 假人發言，只顯示真實登入玩家訊息。 */
(function () {
  'use strict';
  const MAX_MESSAGE_LENGTH = 120;
  let realtimeChannel = null;
  let loaded = false;

  function esc(value) {
    return String(value || '').replace(/[&<>"']/g, function (char) {
      return { '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#039;' }[char];
    });
  }

  function append(message) {
    const log = document.getElementById('world-log');
    if (!log || !message || !message.id) return;
    if (log.querySelector('[data-online-world-id="' + String(message.id) + '"]')) return;
    const row = document.createElement('div');
    row.className = 'online-world-message';
    row.dataset.onlineWorldId = String(message.id);
    const time = message.created_at ? new Date(message.created_at).toLocaleTimeString('zh-TW', { hour:'2-digit', minute:'2-digit' }) : '';
    row.innerHTML = '<span class="online-world-time">[' + esc(time) + ']</span> '
      + '<strong class="online-world-name">' + esc(message.sender_name || '冒險者') + '</strong>：'
      + '<span>' + esc(message.content) + '</span>';
    log.appendChild(row);
    while (log.children.length > 100) log.removeChild(log.firstChild);
    log.scrollTop = log.scrollHeight;
  }

  async function clientReady() {
    const client = typeof window.onlineSupabase === 'function' ? window.onlineSupabase() : null;
    if (!client) return null;
    const result = await client.auth.getUser();
    return result.data && result.data.user ? client : null;
  }

  async function loadAndSubscribe() {
    if (loaded) return;
    const client = await clientReady();
    if (!client) return;
    loaded = true;
    const log = document.getElementById('world-log');
    if (log) log.innerHTML = '';
    const result = await client.from('world_messages')
      .select('id,sender_name,content,created_at')
      .order('id', { ascending:false }).limit(100);
    if (!result.error) (result.data || []).reverse().forEach(append);
    realtimeChannel = client.channel('online-world-channel')
      .on('postgres_changes', { event:'INSERT', schema:'public', table:'world_messages' }, function (payload) { append(payload.new); })
      .subscribe();
  }

  async function send() {
    const input = document.getElementById('world-input');
    const text = String(input && input.value || '').trim();
    if (!text) return;
    if (text.length > MAX_MESSAGE_LENGTH) return alert('世界頻道訊息最多 ' + MAX_MESSAGE_LENGTH + ' 個字。');
    const client = await clientReady();
    if (!client || typeof player === 'undefined' || !player || !player.cloudCharacterId) {
      return alert('請先登入並進入角色存檔，才能使用世界頻道。');
    }
    const result = await client.rpc('send_world_message', {
      p_character_id: player.cloudCharacterId,
      p_content: text
    });
    if (result.error) return alert(result.error.message || '世界頻道送出失敗。');
    input.value = '';
    append(result.data);
  }

  function install() {
    // Legacy NPC broadcasters may continue to write to the same panel after
    // their initial timer has been cleared.  Reserve this panel for real
    // cloud-player messages only.
    window.logWorld = function () {};
    window.worldChannelAsk = send;
    window.worldChannelNpcMenu = function () {};
    window.worldChannelTaunt = function () {};
    window.worldChannelThank = function () {};
    window.worldChannelPrivateChat = function () {};

    const purgeLegacyRows = function () {
      const log = document.getElementById('world-log');
      if (!log) return;
      Array.from(log.children).forEach(function (row) {
        if (!row.dataset || !row.dataset.onlineWorldId) row.remove();
      });
      // 舊版「NPC 收購」釘選廣播不屬於真實世界頻道，公開版一律隱藏。
      const pins = document.getElementById('sys-log-pins');
      if (pins) {
        pins.replaceChildren();
        pins.hidden = true;
      }
    };
    purgeLegacyRows();
    setInterval(purgeLegacyRows, 1000);
    // 停止舊版假人閒聊計時器，並用真正玩家頻道取代舊的問答系統。
    if (typeof _wcIdleTimer !== 'undefined' && _wcIdleTimer) {
      clearInterval(_wcIdleTimer);
      _wcIdleTimer = null;
    }
    window.worldChannelAsk = send;
    const input = document.getElementById('world-input');
    if (input) input.placeholder = '輸入世界頻道訊息（需登入角色存檔）';
    const waitForLogin = setInterval(function () {
      loadAndSubscribe().then(function () {
        if (loaded) clearInterval(waitForLogin);
      }).catch(function () {});
    }, 700);
    loadAndSubscribe().catch(function () {});
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install);
  else install();
})();
