import { Controller } from "@hotwired/stimulus"

// Base map style. Keep in sync with MAP_STYLE_URL in mapbox_controller.js (the live map).
const MAP_STYLE_URL = "https://tiles.openfreemap.org/styles/liberty"

const TOPO_CACHE = "topos-v1"
const APP_CACHE = "app-v1"
const MAP_CACHE = "map-v1"

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

export default class extends Controller {
  static values = { url: String, slug: String }
  static targets = ["button", "progress", "count", "status"]

  connect() {
    if (!("serviceWorker" in navigator) || !("caches" in window)) {
      this.element.classList.add("hidden")
      return
    }
    this.restoreSavedState()
  }

  // Trust the "Saved" flag in localStorage only if the caches still hold the
  // essentials — the browser can evict Cache Storage under disk pressure, and a
  // cache-version bump wipes it. Otherwise reset so the user can re-download.
  async restoreSavedState() {
    const saved = this.savedState
    if (!saved) return

    const style = await caches.match(MAP_STYLE_URL)
    const page = await caches.match(window.location.pathname)
    if (style && page) {
      this.showSaved(saved)
    } else {
      localStorage.removeItem(this.storageKey)
      this.statusTarget.textContent =
        "The offline copy of this area is missing or outdated — please save it again."
      this.statusTarget.classList.remove("hidden")
    }
  }

  async download() {
    this.buttonTarget.disabled = true
    this.progressTarget.classList.remove("hidden")

    try {
      const response = await fetch(this.urlValue)
      const data = await response.json()

      this.failures = []
      const topoCount = await this.downloadTopos(data.topo_urls)
      await this.downloadProblems(data.problem_urls)
      const mapKeys = await this.downloadMap(data)

      const state = {
        downloadedAt: new Date().toISOString(),
        topoCount,
        cachedUrls: data.topo_urls,
        problemUrls: data.problem_urls || [],
        mapKeys,
        failedCount: this.failures.length
      }
      localStorage.setItem(this.storageKey, JSON.stringify(state))
      if (this.failures.length > 0) {
        console.warn("Offline download: failed URLs", this.failures)
      }

      this.progressTarget.classList.add("hidden")
      this.showSaved(state)
    } catch (error) {
      console.error("Offline download failed", error)
      this.progressTarget.classList.add("hidden")
      this.buttonTarget.disabled = false
      alert("Download failed. Check your connection and try again.")
    }
  }

  async downloadTopos(urls) {
    const cache = await caches.open(TOPO_CACHE)
    let count = 0
    for (let i = 0; i < urls.length; i++) {
      this.countTarget.textContent = `Downloading photos: ${i + 1} of ${urls.length}`
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

    // Cache the area page, the map page and the offline-status page HTML for offline
    // navigation, and read the map page for the JS/CSS assets it needs (MapLibre, app
    // bundle, stylesheets).
    await this.cachePage(appCache, window.location.pathname)
    await this.cachePage(appCache, this.offlineStatusPath)
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

    return trackedKeys
  }

  async cachePage(cache, path) {
    const res = await fetch(path)
    if (!res.ok) throw new Error(`Failed to fetch ${path}: ${res.status}`)
    await this.putClean(cache, path, res)
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
      .map(u => { try { return new URL(u, location.origin).href } catch (_) { return null } })
      .filter(u => u && u.startsWith("http"))
  }

  // Fetches each URL and stores it in the given cache, updating the progress label.
  // Failed URLs are recorded in this.failures instead of being silently dropped.
  async cacheAll(cache, urls, label) {
    let done = 0
    for (const url of urls) {
      this.countTarget.textContent = `${label}: ${done + 1} of ${urls.length}`
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

  async clear() {
    const state = this.savedState
    if (state?.cachedUrls) {
      const cache = await caches.open(TOPO_CACHE)
      await Promise.all(state.cachedUrls.map(url => cache.delete(url)))
    }
    if (state?.mapKeys) {
      const cache = await caches.open(MAP_CACHE)
      await Promise.all(state.mapKeys.map(url => cache.delete(url)))
    }
    if (state?.problemUrls) {
      const cache = await caches.open(APP_CACHE)
      await Promise.all(state.problemUrls.map(url => cache.delete(url)))
    }
    localStorage.removeItem(this.storageKey)

    this.statusTarget.classList.add("hidden")
    this.buttonTarget.disabled = false
    this.buttonTarget.textContent = "Save map & photos for offline"
  }

  showSaved(state) {
    const date = new Date(state.downloadedAt).toLocaleDateString()
    this.buttonTarget.disabled = true
    this.buttonTarget.textContent = "Saved"

    const warning = state.failedCount > 0
      ? ` <span class="text-amber-600">${state.failedCount} file${state.failedCount === 1 ? "" : "s"} failed to download — try saving again on a better connection.</span>`
      : ""
    this.statusTarget.innerHTML =
      `Map & ${state.topoCount} photos saved (${date}).${warning} ` +
      `<a href="#" data-action="click->offline-download#clear" class="underline">Remove</a> · ` +
      `<a href="${this.offlineStatusPath}" class="underline">Details</a>`
    this.statusTarget.classList.remove("hidden")
  }

  get offlineStatusPath() {
    const locale = window.location.pathname.split("/")[1] || "en"
    return `/${locale}/offline-status`
  }

  get storageKey() {
    return `offline_area_${this.slugValue}`
  }

  get savedState() {
    const stored = localStorage.getItem(this.storageKey)
    return stored ? JSON.parse(stored) : null
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
