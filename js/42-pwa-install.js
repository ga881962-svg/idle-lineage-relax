/* 手機／桌面 PWA 安裝入口：不影響遊戲與雲端存檔。 */
(function () {
  'use strict';
  var deferredPrompt = null;
  var button = null;

  function isStandalone() {
    return window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone === true;
  }
  function isIOS() {
    return /iphone|ipad|ipod/i.test(navigator.userAgent);
  }
  function showButton() {
    if (!button || isStandalone()) return;
    button.hidden = false;
  }
  function notifyIOS() {
    alert('請在 Safari 點擊下方的「分享」按鈕，再選擇「加入主畫面」，即可安裝放置天堂。\n\n安裝後使用相同帳號登入，網頁、Windows 與手機會共用角色存檔。');
  }
  async function install() {
    if (isIOS()) { notifyIOS(); return; }
    if (!deferredPrompt) {
      alert('尚未出現安裝選項。請確認你是使用 HTTPS 正式網址開啟遊戲，並在 Chrome 選單中點選「安裝應用程式」。');
      return;
    }
    deferredPrompt.prompt();
    try { await deferredPrompt.userChoice; } catch (ignore) {}
    deferredPrompt = null;
    if (button) button.hidden = true;
  }
  function createButton() {
    button = document.createElement('button');
    button.id = 'pwa-install-button';
    button.type = 'button';
    button.hidden = true;
    button.textContent = '📲 安裝手機版';
    button.title = '將遊戲安裝到手機主畫面';
    button.addEventListener('click', install);
    document.body.appendChild(button);
  }

  window.addEventListener('beforeinstallprompt', function (event) {
    event.preventDefault();
    deferredPrompt = event;
    showButton();
  });
  window.addEventListener('appinstalled', function () {
    deferredPrompt = null;
    if (button) button.hidden = true;
  });
  window.addEventListener('DOMContentLoaded', function () {
    createButton();
    if (isIOS() && !isStandalone()) showButton();
  });
})();
