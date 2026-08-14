// Online game: never cache game files. This worker exists only for PWA installation.
// Activating a new version erases every cache left by older builds.
const CACHE_NAME = 'idle-lineage-relax-live-v30-direct-takeover';

self.addEventListener('install', (event) => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});
