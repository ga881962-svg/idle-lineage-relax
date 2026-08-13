/* External static asset URL resolver. Load before every game script. */
(function () {
    'use strict';

    // GCS public asset root. Keep every original assets/... path beneath this root.
    const ASSET_BASE_URL = "https://storage.googleapis.com/idle-lineage-relax-assets-asia-2026";
    const baseUrl = String(ASSET_BASE_URL || '').trim().replace(/\/+$/, '');

    function assetUrl(path) {
        if (path === null || path === undefined || path === '') return path;
        const original = String(path);
        if (/^(?:[a-z][a-z0-9+.-]*:|\/\/|data:|blob:|#)/i.test(original)) return original;
        const match = original.replace(/\\/g, '/').match(/^(?:(?:\.\.\/|\.\/|\/)*)(assets\/.*)$/i);
        return (!match || !baseUrl) ? original : baseUrl + '/' + match[1];
    }

    function assetCssUrl(path) { return 'url("' + assetUrl(path) + '")'; }

    function resolveCssUrls(value) {
        return String(value || '').replace(/url\(\s*(['"]?)(?:(?:\.\.\/|\.\/|\/)*assets\/[^'")\s]+)\1\s*\)/gi, function (whole, quote) {
            const raw = whole.replace(/^url\(\s*['"]?|['"]?\s*\)$/gi, '');
            return 'url(' + (quote || '"') + assetUrl(raw) + (quote || '"') + ')';
        });
    }

    function rewriteElement(element) {
        if (!element || element.nodeType !== 1) return;
        ['src', 'poster'].forEach(function (name) {
            if (!element.hasAttribute(name)) return;
            const raw = element.getAttribute(name), resolved = assetUrl(raw);
            if (resolved !== raw) element.setAttribute(name, resolved);
        });
        if (element.hasAttribute('style')) {
            const raw = element.getAttribute('style'), resolved = resolveCssUrls(raw);
            if (resolved !== raw) element.setAttribute('style', resolved);
        }
    }

    function rewriteTree(root) {
        if (!root) return;
        if (root.nodeType === 1) rewriteElement(root);
        if (root.querySelectorAll) root.querySelectorAll('[src],[poster],[style]').forEach(rewriteElement);
    }

    function patchUrlProperty(proto, property) {
        if (!proto) return;
        const descriptor = Object.getOwnPropertyDescriptor(proto, property);
        if (!descriptor || !descriptor.set || !descriptor.get) return;
        Object.defineProperty(proto, property, {
            configurable: true, enumerable: descriptor.enumerable, get: descriptor.get,
            set: function (value) { descriptor.set.call(this, assetUrl(value)); }
        });
    }

    window.ASSET_BASE_URL = baseUrl;
    window.assetUrl = assetUrl;
    window.assetCssUrl = assetCssUrl;
    // Preserve the GCS resolver if a later legacy script assigns window.assetUrl.
    Object.defineProperty(window, 'assetUrl', {
        configurable: false,
        enumerable: true,
        get: function () { return assetUrl; },
        set: function () { /* Intentionally keep the resolver active. */ }
    });
    patchUrlProperty(window.HTMLImageElement && HTMLImageElement.prototype, 'src');
    patchUrlProperty(window.HTMLMediaElement && HTMLMediaElement.prototype, 'src');

    const applyCssVariables = function () {
        const root = document.documentElement;
        if (!root) return;
        root.style.setProperty('--asset-bg-background', assetCssUrl('assets/background/background.png'));
        root.style.setProperty('--asset-ui-ability', assetCssUrl('assets/ui/能力.png'));
        root.style.setProperty('--asset-ui-bloodbar', assetCssUrl('assets/character/血條底圖.png'));
        root.style.setProperty('--asset-ui-inventory-shell', assetCssUrl('assets/ui/武器防具道具欄位.png'));
        root.style.setProperty('--asset-ui-skill-panel', assetCssUrl('assets/ui/技能欄位.png'));
    };

    applyCssVariables();
    const observe = function () {
        rewriteTree(document.documentElement);
        new MutationObserver(function (records) {
            records.forEach(function (record) {
                if (record.type === 'attributes') rewriteElement(record.target);
                record.addedNodes.forEach(rewriteTree);
            });
        }).observe(document.documentElement, {
            childList: true, subtree: true, attributes: true,
            attributeFilter: ['src', 'poster', 'style']
        });
    };
    if (document.documentElement) observe();
    else document.addEventListener('DOMContentLoaded', observe, { once: true });
})();
