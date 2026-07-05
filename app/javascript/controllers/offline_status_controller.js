import { Controller } from "@hotwired/stimulus"

// Debug read-out for the offline feature (/[locale]/offline-status): reports the
// service worker version, per-cache entry counts, the pinned base-map tile snapshot,
// and — for each saved area — how many of its tracked URLs are actually present in
// Cache Storage. Read-only; nothing here mutates the caches.

const CACHE_NAMES = ["app-v1", "topos-v1", "map-v1"]
const TILEJSON_URL = "https://tiles.openfreemap.org/planet"
const STYLE_URL = "https://tiles.openfreemap.org/styles/liberty"

export default class extends Controller {
  static targets = ["online", "worker", "storage", "caches", "basemap", "areas"]

  async connect() {
    this.onlineTarget.textContent = navigator.onLine ? "online" : "offline"

    if (!("serviceWorker" in navigator) || !("caches" in window)) {
      this.workerTarget.textContent = "not supported in this browser — offline mode unavailable"
      return
    }

    await Promise.all([
      this.reportWorker(),
      this.reportStorage(),
      this.reportCaches(),
      this.reportBasemap(),
      this.reportAreas()
    ])
  }

  async reportWorker() {
    const controller = navigator.serviceWorker.controller
    if (!controller) {
      this.workerTarget.textContent = "not controlling this page (reload once, or first visit)"
      return
    }
    this.workerTarget.textContent = `active (${controller.scriptURL})`

    // Ask the worker for its version; older workers won't answer.
    const version = await new Promise(resolve => {
      const timer = setTimeout(() => resolve(null), 1500)
      navigator.serviceWorker.addEventListener("message", function handler(event) {
        if (event.data?.swVersion) {
          clearTimeout(timer)
          navigator.serviceWorker.removeEventListener("message", handler)
          resolve(event.data.swVersion)
        }
      })
      controller.postMessage("version")
    })
    this.workerTarget.textContent =
      `active, version ${version || "unknown (pre-v2 worker — hard-reload to update)"}`
  }

  async reportStorage() {
    if (!navigator.storage?.estimate) {
      this.storageTarget.textContent = "unknown"
      return
    }
    const { usage, quota } = await navigator.storage.estimate()
    this.storageTarget.textContent = `${formatBytes(usage)} of ${formatBytes(quota)} available`
  }

  async reportCaches() {
    const lines = []
    for (const name of CACHE_NAMES) {
      const cache = await caches.open(name)
      const keys = await cache.keys()
      lines.push(`${name}: ${keys.length} entries`)
    }
    this.cachesTarget.innerHTML = lines.map(l => `<div>${escapeHtml(l)}</div>`).join("")
  }

  async reportBasemap() {
    const style = await caches.match(STYLE_URL)
    const tilejsonRes = await caches.match(TILEJSON_URL)
    if (!style || !tilejsonRes) {
      this.basemapTarget.textContent =
        "Base map style/TileJSON not cached — the map will not work offline. Save an area for offline first."
      return
    }

    const tilejson = await tilejsonRes.clone().json()
    const template = (tilejson.tiles || [])[0] || ""
    const snapshotPrefix = template.split("{")[0]

    const mapKeys = await (await caches.open("map-v1")).keys()
    const tiles = mapKeys.filter(r => snapshotPrefix && r.url.startsWith(snapshotPrefix)).length
    const glyphs = mapKeys.filter(r => r.url.includes("/fonts/")).length
    const sprites = mapKeys.filter(r => r.url.includes("/sprites/")).length
    const staleTiles = mapKeys.filter(r =>
      r.url.includes("/planet/") && snapshotPrefix && !r.url.startsWith(snapshotPrefix)
    ).length

    this.basemapTarget.innerHTML = [
      `Style: cached`,
      `Tile snapshot: ${escapeHtml(snapshotPrefix || "unknown")}`,
      `Tiles cached for this snapshot: ${tiles}`,
      staleTiles > 0 ? `<span class="text-amber-600">Tiles from other (stale) snapshots: ${staleTiles}</span>` : null,
      `Glyphs: ${glyphs} · Sprites: ${sprites}`
    ].filter(Boolean).map(l => `<div>${l}</div>`).join("")
  }

  async reportAreas() {
    const states = Object.keys(localStorage)
      .filter(key => key.startsWith("offline_area_"))
      .map(key => ({ slug: key.replace("offline_area_", ""), ...JSON.parse(localStorage.getItem(key)) }))

    if (states.length === 0) {
      this.areasTarget.textContent = "No areas saved for offline on this device."
      return
    }

    const blocks = []
    for (const state of states) {
      const topos = await this.countCached(state.cachedUrls)
      const pages = await this.countCached(state.problemUrls)
      const mapEntries = await this.countCached(state.mapKeys)
      const date = state.downloadedAt ? new Date(state.downloadedAt).toLocaleString() : "unknown date"

      blocks.push(`
        <div class="mt-2 p-3 rounded border border-gray-200">
          <div class="font-medium text-gray-900">${escapeHtml(state.slug)}</div>
          <div>Saved: ${escapeHtml(date)}</div>
          <div>Topo photos: ${topos.present} of ${topos.total} cached</div>
          <div>Problem pages: ${pages.present} of ${pages.total} cached</div>
          <div>Map files: ${mapEntries.present} of ${mapEntries.total} cached</div>
          ${state.failedCount ? `<div class="text-amber-600">${state.failedCount} files failed during download</div>` : ""}
          ${topos.present < topos.total || pages.present < pages.total || mapEntries.present < mapEntries.total
            ? '<div class="text-amber-600">Incomplete — re-save this area from its page.</div>'
            : '<div class="text-emerald-600">Complete.</div>'}
        </div>`)
    }
    this.areasTarget.innerHTML = blocks.join("")
  }

  async countCached(urls) {
    if (!Array.isArray(urls) || urls.length === 0) return { present: 0, total: 0 }
    let present = 0
    for (const url of urls) {
      if (await caches.match(url, { ignoreVary: true })) present++
    }
    return { present, total: urls.length }
  }
}

function formatBytes(bytes) {
  if (bytes == null) return "unknown"
  if (bytes > 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024 / 1024).toFixed(1)} GB`
  if (bytes > 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`
  return `${Math.round(bytes / 1024)} KB`
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, c => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ))
}
