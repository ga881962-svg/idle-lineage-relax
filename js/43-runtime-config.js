/* Runtime visual/UI configuration.  This is deliberately read-only in the
 * browser: the database remains the source and invalid values always fall
 * back to the production visual baseline. */
(function () {
  'use strict';
  var defaults = Object.freeze({ monster_scale:1, boss_scale:1, player_scale:1, mob_animation_fps:8, exp_multiplier:1, gold_multiplier:1, drop_rate_multiplier:1, ui_entry_visibility:{} });
  var current = Object.assign({}, defaults);

  function finite(value, fallback, min, max) {
    var number = Number(value);
    return Number.isFinite(number) && number >= min && number <= max ? number : fallback;
  }
  function object(value) { return value && typeof value === 'object' && !Array.isArray(value) ? value : {}; }
  function normalized(payload) {
    payload = object(payload);
    var entries = object(payload.ui_entry_visibility);
    var safeEntries = {};
    Object.keys(entries).forEach(function (key) {
      if (/^[a-z0-9_.-]{1,80}$/i.test(key) && typeof entries[key] === 'boolean') safeEntries[key] = entries[key];
    });
    return {
      monster_scale: finite(payload.monster_scale, defaults.monster_scale, 0.5, 2),
      boss_scale: finite(payload.boss_scale, defaults.boss_scale, 0.5, 2),
      player_scale: finite(payload.player_scale, defaults.player_scale, 0.7, 1.4),
      mob_animation_fps: Math.round(finite(payload.mob_animation_fps, defaults.mob_animation_fps, 4, 12)),
      exp_multiplier: finite(payload.exp_multiplier, defaults.exp_multiplier, 0.1, 10),
      gold_multiplier: finite(payload.gold_multiplier, defaults.gold_multiplier, 0.1, 10),
      drop_rate_multiplier: finite(payload.drop_rate_multiplier, defaults.drop_rate_multiplier, 0.1, 10),
      ui_entry_visibility: safeEntries
    };
  }
  function apply(config) {
    current = normalized(config);
    var root = document.documentElement;
    // Existing values are the baseline.  The config is a multiplier, never a
    // replacement size, so front/back/mobile/body proportions stay intact.
    root.style.setProperty('--runtime-mob-front-scale', String(1.3 * current.monster_scale));
    root.style.setProperty('--runtime-mob-back-scale', String(1.1 * current.monster_scale));
    root.style.setProperty('--runtime-boss-scale', String(1.78 * current.boss_scale));
    root.style.setProperty('--runtime-mobile-mob-front-scale', String(0.51 * current.monster_scale));
    root.style.setProperty('--runtime-mobile-mob-back-scale', String(0.42 * current.monster_scale));
    root.style.setProperty('--runtime-mobile-mob-default-scale', String(0.46 * current.monster_scale));
    root.style.setProperty('--runtime-player-width', String((window.matchMedia && window.matchMedia('(max-width:700px)').matches ? 124 : 178) * current.player_scale) + 'px');
    root.style.setProperty('--runtime-player-height', String((window.matchMedia && window.matchMedia('(max-width:700px)').matches ? 120 : 166) * current.player_scale) + 'px');
    document.querySelectorAll('[data-runtime-entry]').forEach(function (element) {
      var key = String(element.getAttribute('data-runtime-entry') || '');
      var visible = !Object.prototype.hasOwnProperty.call(current.ui_entry_visibility, key) || current.ui_entry_visibility[key] !== false;
      element.hidden = !visible;
      element.setAttribute('aria-hidden', visible ? 'false' : 'true');
    });
    window.dispatchEvent(new CustomEvent('idle-runtime-config', { detail:Object.freeze(Object.assign({}, current)) }));
  }
  window.runtimeConfig = function () { return Object.assign({}, current, { ui_entry_visibility:Object.assign({}, current.ui_entry_visibility) }); };
  window.runtimeEntryVisible = function (key) { return current.ui_entry_visibility[String(key)] !== false; };
  window.runtimeConfigApply = apply;
  window.runtimeConfigRefresh = async function () {
    try {
      if (typeof window.onlineCloudApi !== 'function') return false;
      var result = await window.onlineCloudApi({ action:'runtime.config.read' });
      apply(result && result.config);
      return true;
    } catch (_) {
      apply(defaults);
      return false;
    }
  };
  apply(defaults);
  window.addEventListener('resize', function () { apply(current); });
})();
