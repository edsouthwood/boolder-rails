// Saving areas for offline use: downloads everything an area needs into Cache Storage
// (served by public/service-worker.js) and tracks each saved area in localStorage
// under `offline_area_<slug>`. Shared by the area page's save button
// (offline_download_controller.js), "My downloads" (offline_downloads_controller.js)
// and the home page's saved list (saved_areas_controller.js).

// Base map style. Keep in sync with MAP_STYLE_URL in mapbox_controller.js (the live map).
const MAP_STYLE_URL = "https://tiles.openfreemap.org/styles/liberty"

export const TOPO_CACHE = "topos-v1"
export const APP_CACHE = "app-v1"
export const MAP_CACHE = "map-v1"
export const IMAGE_CACHE = "images-v1"

// Cross-origin hosts the service worker serves offline. Keep in sync with
// MAP_ASSET_HOSTS in public/service-worker.js: anything else (e.g. the Bugsnag
// script, whose CDN refuses CORS fetches) would never be served from cache anyway.
const OFFLINE_ASSET_HOSTS = ["tiles.openfreemap.org", "cdn.jsdelivr.net", "ga.jspm.io"]

// Base map tiles are only fetched up to this zoom; MapLibre over-zooms the deepest
// tile for the closer (z15+) problem/boulder views, so we never need deeper tiles.
const MAX_TILE_ZOOM = 14
// Glyph ranges covering basic + extended Latin — enough for English place names.
// Rare characters may be missing offline; labels degrade gracefully.
const GLYPH_RANGES = ["0-255", "256-511"]
// Fontstacks used by the overlay layers that mapbox_controller adds at runtime
// (area names, circuit numbers). Keep in sync with the text-font values there.
const OVERLAY_FONTSTACKS = [
  "Noto Sans Bold",
  "Noto Sans Regular"
]

const STORAGE_PREFIX = "offline_area_"

export function offlineSupported() {
  return "serviceWorker" in navigator && "caches" in window
}

// Whether the server is actually reachable. navigator.onLine only knows about the
// device's network link: on the moor a phone often shows signal while nothing gets
// through. Pings the health check past the service worker (sw-bypass).
export async function reachable(timeoutMs = 4000) {
  if (navigator.onLine === false) return false
  try {
    const res = await fetch(`/up?sw-bypass=${Date.now()}`, {
      cache: "no-store", signal: AbortSignal.timeout(timeoutMs)
    })
    return res.ok
  } catch (_) {
    return false
  }
}

export function locale() {
  return window.location.pathname.split("/")[1] || "en"
}

export function savedState(slug) {
  try {
    return JSON.parse(localStorage.getItem(STORAGE_PREFIX + slug))
  } catch (_) {
    return null
  }
}

// Every saved area as { slug, name, path, ...state }, sorted by name. Saves made
// before name/path were stored fall back to the slug.
export function savedAreas() {
  const areas = []
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i)
    if (!key?.startsWith(STORAGE_PREFIX)) continue
    const slug = key.slice(STORAGE_PREFIX.length)
    const state = savedState(slug) || {}
    areas.push({
      ...state,
      slug,
      name: state.name || slug.replace(/-/g, " ").replace(/\b\w/g, c => c.toUpperCase()),
      path: state.path || `/${locale()}/dartmoor/${slug}`
    })
  }
  return areas.sort((a, b) => a.name.localeCompare(b.name))
}

// True when the server's current version differs from the saved copy's. Saves from
// before versions existed count as outdated: there's no way to tell.
export function isOutdated(state, currentVersion) {
  return !!state && !!currentVersion && state.version !== currentVersion
}

// Trust the saved flag only if the caches still hold the essentials — the browser can
// evict Cache Storage under disk pressure, and a cache-version bump wipes it.
export async function isIntact(state) {
  if (!state) return false
  const page = state.path || state.pageUrls?.[0]
  const [style, cachedPage] = await Promise.all([
    caches.match(MAP_STYLE_URL),
    page ? caches.match(page) : Promise.resolve(true)
  ])
  return !!(style && cachedPage)
}

// Downloads (or re-downloads) an area from its offline-data endpoint and records it.
// `onProgress(text)` receives status lines. Re-downloading an already saved area is an
// update: files the new copy no longer needs are removed afterwards, unless another
// saved area still uses them. Throws if the essentials fail; individual file failures
// are only counted (state.failedCount).
export async function downloadArea(dataUrl, onProgress = () => {}) {
  const response = await fetch(dataUrl)
  if (!response.ok) throw new Error(`Failed to fetch ${dataUrl}: ${response.status}`)
  const data = await response.json()
  const previous = savedState(data.slug)

  const downloader = new AreaDownloader(onProgress)
  const topoCount = await downloader.downloadTopos(data.topo_urls)
  await downloader.downloadProblems(data.problem_urls)
  const mapKeys = await downloader.downloadMap(data)

  const state = {
    name: data.name,
    path: data.area_url,
    version: data.version,
    downloadedAt: new Date().toISOString(),
    topoCount,
    cachedUrls: data.topo_urls,
    problemUrls: data.problem_urls || [],
    pageUrls: [data.area_url],
    mapKeys,
    failedCount: downloader.failures.length
  }
  localStorage.setItem(STORAGE_PREFIX + data.slug, JSON.stringify(state))
  if (downloader.failures.length > 0) {
    console.warn("Offline download: failed URLs", downloader.failures)
  }
  if (previous) await deleteUnused(previous)

  // Ask the browser not to evict saved areas under storage pressure. Chrome
  // grants it silently for installed or frequently used sites; Firefox asks.
  navigator.storage?.persist?.().catch(() => {})
  return { slug: data.slug, ...state }
}

// Removes a saved area's files, keeping any that another saved area also uses (the
// base map style, shared low-zoom tiles, overlapping tiles of neighbouring areas).
export async function removeArea(slug) {
  const state = savedState(slug)
  localStorage.removeItem(STORAGE_PREFIX + slug)
  if (state) await deleteUnused(state)
}

// Deletes `state`'s tracked files that no currently saved area refers to. On an
// update the new copy is already saved, so everything it still needs is kept.
async function deleteUnused(state) {
  const inUse = new Set()
  for (const area of savedAreas()) {
    trackedUrls(area).forEach(url => inUse.add(url))
  }
  const unused = trackedUrls(state).filter(url => !inUse.has(url))
  if (unused.length === 0) return
  const names = [TOPO_CACHE, MAP_CACHE, APP_CACHE]
  const opened = await Promise.all(names.map(name => caches.open(name)))
  await Promise.all(unused.flatMap(url => opened.map(cache => cache.delete(url))))
}

function trackedUrls(state) {
  return [
    ...(state.cachedUrls || []),
    ...(state.problemUrls || []),
    ...(state.pageUrls || []),
    ...(state.mapKeys || [])
  ]
}

// Approximate bytes a saved area occupies (shared files are counted for every area
// that uses them, so the sum over areas can exceed the real total).
export async function areaSize(state) {
  let bytes = 0
  for (const url of trackedUrls(state)) {
    const cached = await caches.match(url, { ignoreVary: true })
    if (!cached) continue
    const length = Number(cached.headers.get("content-length"))
    bytes += length > 0 ? length : (await cached.blob()).size
  }
  return bytes
}

export function formatBytes(bytes) {
  if (bytes == null) return "unknown"
  if (bytes > 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024 / 1024).toFixed(1)} GB`
  if (bytes > 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`
  return `${Math.round(bytes / 1024)} KB`
}

class AreaDownloader {
  constructor(onProgress) {
    this.onProgress = onProgress
    this.failures = []
  }

  async downloadTopos(urls) {
    const cache = await caches.open(TOPO_CACHE)
    let count = 0
    for (let i = 0; i < urls.length; i++) {
      this.onProgress(`Downloading photos: ${i + 1} of ${urls.length}`)
      try {
        await cache.add(urls[i])
        count++
      } catch (_) {
        this.failures.push(urls[i])
      }
    }
    return count
  }

  // Pre-fetch the area's problem pages into APP_CACHE so the navigate handler serves them
  // offline when a problem is tapped on the map.
  async downloadProblems(urls) {
    if (!urls || urls.length === 0) return
    const cache = await caches.open(APP_CACHE)
    await this.cacheAll(cache, urls, "Downloading problems")
  }

  // Pre-fetches everything the map needs offline: the area HTML page, the overlay
  // GeoJSON, and the base map (style, vector tiles for the area's bounds, glyphs,
  // sprites). Returns the list of map-cache keys so they can be cleared later.
  // Failures of the essentials (pages, style, TileJSON) throw and abort the download;
  // individual tile/glyph failures are only counted.
  async downloadMap(data) {
    const mapCache = await caches.open(MAP_CACHE)
    const appCache = await caches.open(APP_CACHE)

    // Cache the area page, the home page (the installed app's start screen, which
    // lists saved areas), "My downloads", the map page and the offline-status page HTML
    // for offline navigation, plus the photos the area and home pages show; and read
    // the map page for the JS/CSS assets it needs (MapLibre, app bundle, stylesheets).
    const pageImageUrls = [
      ...this.parsePageImages(await this.cachePage(appCache, data.area_url)),
      ...this.parsePageImages(await this.cachePage(appCache, `/${locale()}`))
    ]
    await this.cachePage(appCache, `/${locale()}/downloads`)
    await this.cachePage(appCache, `/${locale()}/offline-status`)
    if (data.map_index_url) await this.cachePage(appCache, data.map_index_url)
    const shellUrls = await this.cacheMapPage(appCache, data.map_url)

    // Base map style + its tiles/glyphs/sprites, and the overlay GeoJSON. The style
    // and TileJSON are fetched FRESH (bypassing the service worker's cache-first) and
    // re-pinned under their canonical URLs: OpenFreeMap tile URLs contain a dated
    // snapshot that rotates, and downloading tiles for a stale cached snapshot yields
    // 404s for every tile — an invisibly empty offline map.
    const style = await this.fetchFreshJson(mapCache, MAP_STYLE_URL)
    const { assetUrls, tilejsonUrls } = await this.collectMapAssetUrls(mapCache, style, data.bounds)
    const overlayUrls = [data.map_data_url, data.area_labels_url].filter(Boolean)

    // Tracked keys are the per-area entries removed on "Remove"; the shared app/library
    // shell assets are pre-fetched too but left cached for any other offline area.
    const trackedKeys = [MAP_STYLE_URL, ...tilejsonUrls, ...overlayUrls, ...assetUrls]
    await this.cacheAll(mapCache, [...overlayUrls, ...assetUrls, ...shellUrls], "Downloading map")
    await this.cacheAll(await caches.open(IMAGE_CACHE), [...new Set(pageImageUrls)], "Downloading photos")

    return trackedKeys
  }

  // Caches a page's HTML and returns it, so callers can read the assets it uses.
  async cachePage(cache, path) {
    const res = await fetch(path)
    if (!res.ok) throw new Error(`Failed to fetch ${path}: ${res.status}`)
    await this.putClean(cache, path, res.clone())
    return res.text()
  }

  // Caches the map page HTML and returns the asset URLs it references so they can be
  // pre-fetched for offline use.
  async cacheMapPage(cache, mapUrl) {
    const res = await fetch(mapUrl)
    if (!res.ok) throw new Error(`Failed to fetch ${mapUrl}: ${res.status}`)
    await this.putClean(cache, mapUrl, res.clone())
    return this.parsePageAssets(await res.text())
  }

  // Extracts the JS/CSS asset URLs a page depends on: importmap module URLs plus any
  // <link href> / <script src> (stylesheets, MapLibre + importmap-shim from the CDN).
  parsePageAssets(html) {
    const urls = new Set()
    const doc = new DOMParser().parseFromString(html, "text/html")

    const importmap = doc.querySelector('script[type="importmap"]')
    if (importmap) {
      try {
        const imports = JSON.parse(importmap.textContent).imports || {}
        Object.values(imports).forEach(u => urls.add(u))
      } catch (_) {}
    }

    // Only real page assets — link tags like canonical/alternate/icon would add
    // bogus (and sometimes cross-scheme) URLs to the download list.
    const ASSET_LINK_RELS = ["stylesheet", "preload", "modulepreload"]
    doc.querySelectorAll("link[href], script[src]").forEach(el => {
      if (el.tagName === "LINK" && !ASSET_LINK_RELS.includes(el.getAttribute("rel"))) return
      const u = el.getAttribute("href") || el.getAttribute("src")
      if (u) urls.add(u)
    })

    return [...urls]
      .map(u => { try { return new URL(u, location.origin) } catch (_) { return null } })
      .filter(u => u && (u.origin === location.origin || OFFLINE_ASSET_HOSTS.includes(u.hostname)))
      .map(u => u.href)
  }

  // Same-origin Active Storage photos a page shows: <img src> and inline
  // background-image: url(...) (area cards). Served cache-first by the service worker.
  parsePageImages(html) {
    const doc = new DOMParser().parseFromString(html, "text/html")
    const urls = [...doc.querySelectorAll("img[src]")].map(img => img.getAttribute("src"))
    doc.querySelectorAll("[style*='url(']").forEach(el => {
      const match = el.getAttribute("style").match(/url\(['"]?([^'")]+)['"]?\)/)
      if (match) urls.push(match[1])
    })
    return urls
      .map(u => { try { return new URL(u, location.origin) } catch (_) { return null } })
      .filter(u => u && u.origin === location.origin && u.pathname.startsWith("/rails/active_storage/"))
      .map(u => u.href)
  }

  // Fetches each URL and stores it in the given cache, updating the progress label.
  // Failed URLs are recorded in this.failures instead of being silently dropped.
  async cacheAll(cache, urls, label) {
    let done = 0
    for (const url of urls) {
      this.onProgress(`${label}: ${done + 1} of ${urls.length}`)
      try {
        const res = await fetch(url)
        if (res.ok) {
          await this.putClean(cache, url, res)
        } else {
          this.failures.push(`${url} (${res.status})`)
        }
      } catch (_) {
        this.failures.push(url)
      }
      done++
    }
  }

  // Fetches a fresh copy from the network — the sw-bypass param makes the service
  // worker step aside, and its unique value defeats the HTTP cache — then pins the
  // result under the canonical URL so cache-first lookups (online and offline) get it.
  async fetchFreshJson(cache, url) {
    const busted = url + (url.includes("?") ? "&" : "?") + "sw-bypass=" + Date.now()
    const res = await fetch(busted, { cache: "no-store" })
    if (!res.ok) throw new Error(`Failed to fetch ${url}: ${res.status}`)
    await this.putClean(cache, url, res.clone())
    return res.json()
  }

  // cache.put, unwrapping redirected responses: a response with `redirected: true`
  // served to a later navigation request is a network error in Chrome.
  async putClean(cache, key, res) {
    if (!res.redirected) return cache.put(key, res)
    const body = await res.blob()
    return cache.put(key, new Response(body, {
      status: res.status, statusText: res.statusText, headers: res.headers
    }))
  }

  // Builds the list of base-map asset URLs (tiles, glyphs, sprites) referenced by a
  // style. Returns the TileJSON URLs separately: those are cached (fresh) as a side
  // effect here, so they belong in the tracked keys but not in the re-fetch list.
  async collectMapAssetUrls(cache, style, bounds) {
    const assetUrls = []
    const tilejsonUrls = []

    // Sprites: <base>.json / <base>.png plus @2x variants
    const sprites = Array.isArray(style.sprite)
      ? style.sprite.map(s => s.url)
      : (style.sprite ? [style.sprite] : [])
    for (const base of sprites) {
      assetUrls.push(`${base}.json`, `${base}.png`, `${base}@2x.json`, `${base}@2x.png`)
    }

    // Glyphs: one request per (fontstack, range)
    if (style.glyphs) {
      for (const stack of this.fontstacks(style)) {
        for (const range of GLYPH_RANGES) {
          assetUrls.push(
            style.glyphs
              .replace("{fontstack}", encodeURIComponent(stack))
              .replace("{range}", range)
          )
        }
      }
    }

    // Vector tiles for each source, covering the area bounds
    for (const source of Object.values(style.sources || {})) {
      const tileset = await this.resolveTileset(cache, source)
      if (!tileset) continue
      if (tileset.tilejsonUrl) tilejsonUrls.push(tileset.tilejsonUrl)
      assetUrls.push(...this.tileUrls(tileset, bounds))
    }

    return { assetUrls, tilejsonUrls }
  }

  fontstacks(style) {
    const stacks = new Set(OVERLAY_FONTSTACKS)
    for (const layer of style.layers || []) {
      const font = layer.layout && layer.layout["text-font"]
      if (Array.isArray(font)) stacks.add(font.join(","))
    }
    return stacks
  }

  // Returns { tiles: [template], maxzoom, tilejsonUrl? } for a vector/raster source.
  // A TileJSON referenced by URL is fetched fresh and pinned under its canonical URL,
  // so the tile snapshot we download always matches the TileJSON MapLibre will read.
  async resolveTileset(cache, source) {
    if (source.type !== "vector" && source.type !== "raster") return null
    if (Array.isArray(source.tiles)) {
      return { tiles: source.tiles, maxzoom: source.maxzoom }
    }
    if (source.url && !source.url.endsWith(".pmtiles")) {
      const tilejson = await this.fetchFreshJson(cache, source.url)
      if (Array.isArray(tilejson.tiles)) {
        return { tiles: tilejson.tiles, maxzoom: tilejson.maxzoom, tilejsonUrl: source.url }
      }
    }
    return null
  }

  tileUrls(tileset, bounds) {
    const template = tileset.tiles[0].replace("{s}", "a")
    const maxZoom = Math.min(tileset.maxzoom ?? MAX_TILE_ZOOM, MAX_TILE_ZOOM)
    const urls = []

    for (let z = 0; z <= maxZoom; z++) {
      const xMin = lon2tile(bounds.southWestLon, z)
      const xMax = lon2tile(bounds.northEastLon, z)
      const yMin = lat2tile(bounds.northEastLat, z) // north → smaller y
      const yMax = lat2tile(bounds.southWestLat, z)

      for (let x = xMin; x <= xMax; x++) {
        for (let y = yMin; y <= yMax; y++) {
          urls.push(
            template.replace("{z}", z).replace("{x}", x).replace("{y}", y)
          )
        }
      }
    }
    return urls
  }
}

// --- Web Mercator tile math (XYZ scheme) ---

function lon2tile(lon, z) {
  return Math.floor(((lon + 180) / 360) * Math.pow(2, z))
}

function lat2tile(lat, z) {
  const rad = (lat * Math.PI) / 180
  return Math.floor(
    ((1 - Math.log(Math.tan(rad) + 1 / Math.cos(rad)) / Math.PI) / 2) * Math.pow(2, z)
  )
}

// --- Offline search ---

// Searches the map data saved with offline areas (all published problems + area labels)
// when the server can't be reached. Returns results shaped like /search's JSON, plus
// `path`, limited to pages actually saved on this device (an unsaved one would only
// open the "You're offline" page).
export async function searchOffline(query, localeCode = locale()) {
  const terms = normalize(query).split(" ").filter(Boolean)
  if (terms.length === 0) return []

  const [problems, areas] = await Promise.all([
    cachedFeatures(`/${localeCode}/map-data.geojson`),
    cachedFeatures(`/${localeCode}/area-labels.geojson`)
  ])

  const areaResults = rank(areas.filter(f => f.properties.path), terms).slice(0, 10)
    .map(f => ({
      type: "Area",
      id: f.id,
      name: f.properties.name,
      path: f.properties.path,
      bounds: {
        south_west: { lat: f.properties.southWestLat, lng: f.properties.southWestLon },
        north_east: { lat: f.properties.northEastLat, lng: f.properties.northEastLon }
      }
    }))
  const problemResults = rank(problems.filter(f => f.properties.path), terms).slice(0, 30)
    .map(f => ({
      type: "Problem",
      id: f.properties.id,
      name: f.properties.name,
      grade: f.properties.grade,
      area_name: f.properties.areaName || "",
      circuit_number: f.properties.circuitNumber,
      path: f.properties.path,
      geolocation: { lat: f.geometry.coordinates[1], lng: f.geometry.coordinates[0] }
    }))

  const saved = async result => !!(await caches.match(result.path))
  const keep = await Promise.all([...areaResults, ...problemResults].map(saved))
  const results = [...areaResults, ...problemResults].filter((_, i) => keep[i])
  return [...results.filter(r => r.type === "Area"), ...results.filter(r => r.type === "Problem").slice(0, 10)]
}

async function cachedFeatures(url) {
  try {
    const cached = await caches.match(url, { ignoreVary: true })
    return cached ? ((await cached.json()).features || []).filter(f => f.properties?.name) : []
  } catch (_) {
    return []
  }
}

// Every term must appear in the name; whole-name and word-start matches rank first.
function rank(features, terms) {
  const query = terms.join(" ")
  return features
    .map(feature => {
      const name = normalize(feature.properties.name)
      if (!terms.every(term => name.includes(term))) return null
      const words = name.split(" ")
      const score = name === query ? 0
        : name.startsWith(query) ? 1
        : terms.every(term => words.some(word => word.startsWith(term))) ? 2
        : 3
      return { feature, score, length: name.length }
    })
    .filter(Boolean)
    .sort((a, b) => a.score - b.score || a.length - b.length)
    .map(match => match.feature)
}

// Lowercase, accents stripped, punctuation as spaces: "Tim's Slab" ~ "tims slab".
function normalize(text) {
  return String(text || "")
    .normalize("NFD").replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/['’]/g, "")
    .replace(/[^a-z0-9+]+/g, " ")
    .trim()
}
