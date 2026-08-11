/* Keeps the display's own files available offline, so a reload during a network
   drop lands on the page again instead of the browser's "server not found"
   screen. Network first, so a deploy still lands on the next load; the cache is
   only the fallback. YouTube is another origin and always hits the network. */
const CACHE = 'lab-display';
// Both names for the page: Vercel serves it at './', a local server at its
// filename. Whichever one the display is opened with has to be in the cache.
const SHELL = ['./', 'lab-display.html', 'logo.png', 'CPL_Logo.png', 'school1.png', 'AccentColo.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('fetch', e => {
  if (new URL(e.request.url).origin !== location.origin) return;

  e.respondWith(
    fetch(e.request)
      .then(res => {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(e.request, copy));
        return res;
      })
      // ignoreSearch so the ?v= cache-buster on the TV's URL still matches.
      .catch(() => caches.match(e.request, { ignoreSearch: true }))
  );
});
