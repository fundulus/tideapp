// Service worker: makes Tides installable and usable offline.
//
// The offline story is the point of this file. The four Baja sites compute entirely
// in-page from embedded harmonic constants, so once the shell is cached they work
// with no signal at all, which is the situation at Bahia de los Angeles. NOAA
// stations still need the network, but recent responses are kept so a station
// visited before the trip still answers in the field.
//
// Bump CACHE_VERSION on every deploy; the old caches are dropped on activate.

const CACHE_VERSION = "tides-20260807080733";
const SHELL_CACHE = CACHE_VERSION + "-shell";
const DATA_CACHE = CACHE_VERSION + "-noaa";

const SHELL = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/apple-touch-icon.png"
];

self.addEventListener("install", event => {
  event.waitUntil(
    caches.open(SHELL_CACHE)
      // Individually, so one 404 cannot fail the whole install.
      .then(cache => Promise.all(SHELL.map(url => cache.add(url).catch(() => null))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(k => k !== SHELL_CACHE && k !== DATA_CACHE).map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", event => {
  const req = event.request;
  if (req.method !== "GET") return;

  let url;
  try { url = new URL(req.url); } catch (e) { return; }

  // NOAA predictions: network first, so an online user always sees current data and
  // never a stale table. The cached copy exists only as a fallback once out of signal.
  if (url.hostname.endsWith("tidesandcurrents.noaa.gov")) {
    event.respondWith(
      fetch(req)
        .then(res => {
          if (res.ok) {
            const copy = res.clone();
            caches.open(DATA_CACHE).then(c => c.put(req, copy));
          }
          return res;
        })
        .catch(() => caches.match(req).then(hit => hit || Response.error()))
    );
    return;
  }

  if (url.origin !== self.location.origin) return;

  // The document itself: network first so a deploy is picked up on the next launch
  // rather than being pinned by the cache, falling back to the cached shell offline.
  if (req.mode === "navigate") {
    event.respondWith(
      fetch(req)
        .then(res => {
          const copy = res.clone();
          caches.open(SHELL_CACHE).then(c => c.put("./index.html", copy));
          return res;
        })
        .catch(() => caches.match("./index.html").then(hit => hit || caches.match("./")))
    );
    return;
  }

  // Static assets: cache first, refreshed quietly in the background.
  event.respondWith(
    caches.match(req).then(hit => {
      const net = fetch(req).then(res => {
        if (res.ok) {
          const copy = res.clone();
          caches.open(SHELL_CACHE).then(c => c.put(req, copy));
        }
        return res;
      }).catch(() => hit);
      return hit || net;
    })
  );
});
