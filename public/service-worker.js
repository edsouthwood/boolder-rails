const APP_CACHE = 'app-v1'
const TOPO_CACHE = 'topos-v1'

self.addEventListener('install', event => {
  self.skipWaiting()
})

self.addEventListener('activate', event => {
  // Remove caches from old versions
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(
        keys
          .filter(key => key !== APP_CACHE && key !== TOPO_CACHE)
          .map(key => caches.delete(key))
      )
    ).then(() => clients.claim())
  )
})

self.addEventListener('fetch', event => {
  const { request } = event
  const url = new URL(request.url)

  if (url.origin !== self.location.origin) return

  // Cache-first for topo images — once cached, never re-fetch until cleared
  if (url.pathname.startsWith('/proxy/topos/')) {
    event.respondWith(
      caches.open(TOPO_CACHE).then(cache =>
        cache.match(request).then(cached => {
          if (cached) return cached
          return fetch(request).then(response => {
            cache.put(request, response.clone())
            return response
          })
        })
      )
    )
    return
  }

  // Network-first for HTML page navigations, cache as fallback when offline
  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then(response => {
          const clone = response.clone()
          caches.open(APP_CACHE).then(cache => cache.put(request, clone))
          return response
        })
        .catch(() => caches.match(request))
    )
  }
})
