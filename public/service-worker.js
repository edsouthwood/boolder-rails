const APP_CACHE = 'app-v1'
const TOPO_CACHE = 'topos-v1'
const MAP_CACHE = 'map-v1'

// Cross-origin hosts whose static assets make the map usable offline:
// the OpenFreeMap base map (style, vector/raster tiles, glyphs, sprites) and the
// CDN-hosted map libraries (MapLibre GL, the importmap shim/modules). All are
// immutable/versioned, so cache-first is safe. Pre-downloaded by
// offline_download_controller.js; also populated as the user browses online.
const MAP_ASSET_HOSTS = ['tiles.openfreemap.org', 'cdn.jsdelivr.net', 'ga.jspm.io']

self.addEventListener('install', event => {
  self.skipWaiting()
})

self.addEventListener('activate', event => {
  // Remove caches from old versions
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(
        keys
          .filter(key => key !== APP_CACHE && key !== TOPO_CACHE && key !== MAP_CACHE)
          .map(key => caches.delete(key))
      )
    ).then(() => clients.claim())
  )
})

// Cache-first: serve from cache when present, otherwise fetch and store.
function cacheFirst(event, cacheName) {
  event.respondWith(
    caches.open(cacheName).then(cache =>
      cache.match(event.request).then(cached => {
        if (cached) return cached
        return fetch(event.request).then(response => {
          cache.put(event.request, response.clone())
          return response
        })
      })
    )
  )
}

// A guaranteed-non-null offline page for uncached navigations.
function offlinePage() {
  return new Response(
    '<!doctype html><html><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width, initial-scale=1">' +
    '<title>Offline</title></head>' +
    '<body style="font-family:sans-serif;text-align:center;padding:3rem 1.5rem;color:#374151">' +
    "<h1 style=\"font-size:1.25rem\">You're offline</h1>" +
    '<p style="color:#6b7280">This page hasn\'t been saved for offline use. ' +
    'Reconnect, or save the area for offline from its page.</p></body></html>',
    { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } }
  )
}

// A guaranteed-non-null empty GeoJSON response for uncached overlay data.
function emptyGeojson() {
  return new Response(
    '{"type":"FeatureCollection","features":[]}',
    { status: 200, headers: { 'Content-Type': 'application/json' } }
  )
}

// Network-first: use the network when online (refreshing the cache), fall back to
// the cached copy when offline, then to `fallback()` so we never resolve with null
// (event.respondWith(undefined) throws "Returned response is null").
function networkFirst(event, cacheName, fallback) {
  event.respondWith(
    fetch(event.request)
      .then(response => {
        const clone = response.clone()
        caches.open(cacheName).then(cache => cache.put(event.request, clone))
        return response
      })
      .catch(() => caches.match(event.request).then(cached => cached || fallback()))
  )
}

self.addEventListener('fetch', event => {
  const { request } = event
  if (request.method !== 'GET') return

  const url = new URL(request.url)

  // Cross-origin map assets (base map + map libraries): cache-first
  if (MAP_ASSET_HOSTS.includes(url.hostname)) {
    cacheFirst(event, MAP_CACHE)
    return
  }

  if (url.origin !== self.location.origin) return

  // Fingerprinted app shell assets (JS/CSS) are immutable: cache-first so the
  // app and map render offline without relying on the browser HTTP cache.
  if (url.pathname.startsWith('/assets/')) {
    cacheFirst(event, MAP_CACHE)
    return
  }

  // Map overlay data (localized, e.g. /en/map-data.geojson): network-first,
  // falling back to the pre-downloaded copy offline
  if (/\/(map-data|area-labels)\.geojson$/.test(url.pathname)) {
    networkFirst(event, MAP_CACHE, emptyGeojson)
    return
  }

  // Topo images — once cached, never re-fetch until cleared
  if (url.pathname.startsWith('/proxy/topos/')) {
    cacheFirst(event, TOPO_CACHE)
    return
  }

  // HTML page navigations: network-first, cached page as fallback when offline,
  // then a friendly offline page so we never crash with a null response.
  if (request.mode === 'navigate') {
    networkFirst(event, APP_CACHE, offlinePage)
  }
})
