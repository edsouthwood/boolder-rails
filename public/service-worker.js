// Bump on every change so DevTools/offline-status can confirm which version is live.
const SW_VERSION = '2'

const APP_CACHE = 'app-v1'
const TOPO_CACHE = 'topos-v1'
const MAP_CACHE = 'map-v1'

// How long to wait for the network before falling back to cache. On a poor signal
// (the normal case on the moor) fetch can hang for tens of seconds before failing;
// without this the app looks broken even though everything is cached.
const NETWORK_TIMEOUT_MS = 3500

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

// Report the live version to pages (used by the /offline-status debug page).
self.addEventListener('message', event => {
  if (event.data === 'version') event.source.postMessage({ swVersion: SW_VERSION })
})

// Cache `response` under `request`, unwrapping redirected responses first: serving a
// response with `redirected: true` to a navigation request is a network error in
// Chrome ("a redirected response was used for a request whose redirect mode is not
// 'follow'"), so store a clean copy instead.
async function putInCache(cacheName, request, response) {
  const cache = await caches.open(cacheName)
  if (!response.redirected) return cache.put(request, response)
  const body = await response.blob()
  return cache.put(request, new Response(body, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers
  }))
}

function cacheable(response) {
  // Opaque responses (no-cors <script>/<img> fetches) report status 0 but are
  // still servable from cache; don't cache errors (404 glyphs, 500s).
  return response.ok || response.type === 'opaque'
}

// Cache-first: serve from cache when present, otherwise fetch and store. Never
// rejects — an uncached miss while offline returns a synthetic 504 so the
// FetchEvent doesn't crash (MapLibre treats it like any failed tile).
function cacheFirst(event, cacheName) {
  event.respondWith(
    caches.match(event.request, { ignoreVary: true }).then(cached => {
      if (cached) return cached
      return fetch(event.request).then(response => {
        if (cacheable(response)) putInCache(cacheName, event.request, response.clone())
        return response
      })
    }).catch(() => new Response('', { status: 504, statusText: 'Offline' }))
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

// Network-first with a timeout: use the network when it answers promptly
// (refreshing the cache), otherwise fall back to the cached copy, then to
// `fallback()` so we never resolve with null (event.respondWith(undefined)
// throws "Returned response is null"). A slow network response still lands in
// the cache for next time even after we've already served the cached copy.
function networkFirst(event, cacheName, fallback) {
  const fromNetwork = fetch(event.request).then(response => {
    if (cacheable(response)) putInCache(cacheName, event.request, response.clone())
    return response
  })
  fromNetwork.catch(() => {}) // fallback path below; avoid an unhandled rejection

  const fromCache = () =>
    caches.match(event.request, { ignoreVary: true }).then(cached => cached || fallback())

  event.respondWith(
    Promise.race([
      fromNetwork,
      new Promise(resolve => setTimeout(resolve, NETWORK_TIMEOUT_MS))
    ])
      .then(response => response || fromCache())
      .catch(fromCache)
  )
}

// HTML requests come in two flavours: real navigations (address bar, target=_blank
// popup links) and Turbo Drive visits, which are plain fetches with mode "same-origin"
// — matching only request.mode === 'navigate' misses every in-page link click.
function isHtmlRequest(request) {
  if (request.mode === 'navigate') return true
  const accept = request.headers.get('Accept') || ''
  return request.destination === '' && accept.includes('text/html')
}

self.addEventListener('fetch', event => {
  const { request } = event
  if (request.method !== 'GET') return

  const url = new URL(request.url)

  // Escape hatch for the download controller: fetch a genuinely fresh copy,
  // bypassing both this worker's caches and (via the unique param value) the
  // HTTP cache. Nothing is stored under the busted URL.
  if (url.searchParams.has('sw-bypass')) return

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
  if (/\/(map-data|area-labels)(\.geojson)?$/.test(url.pathname)) {
    networkFirst(event, MAP_CACHE, emptyGeojson)
    return
  }

  // Topo images — once cached, never re-fetch until cleared
  if (url.pathname.startsWith('/proxy/topos/')) {
    cacheFirst(event, TOPO_CACHE)
    return
  }

  // HTML pages (real navigations and Turbo visits): network-first, cached page as
  // fallback when offline, then a friendly offline page so we never crash with a
  // null response.
  if (isHtmlRequest(request)) {
    networkFirst(event, APP_CACHE, offlinePage)
  }
})
