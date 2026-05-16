import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String, slug: String }
  static targets = ["button", "progress", "count", "status"]

  connect() {
    if (!("serviceWorker" in navigator) || !("caches" in window)) {
      this.element.classList.add("hidden")
      return
    }
    const saved = this.savedState
    if (saved) this.showSaved(saved)
  }

  async download() {
    this.buttonTarget.disabled = true

    try {
      const response = await fetch(this.urlValue)
      const data = await response.json()
      const urls = data.topo_urls

      this.progressTarget.classList.remove("hidden")

      const cache = await caches.open("topos-v1")
      const cachedUrls = []

      for (let i = 0; i < urls.length; i++) {
        this.countTarget.textContent = `${i + 1} of ${urls.length}`
        try {
          await cache.add(urls[i])
          cachedUrls.push(urls[i])
        } catch (_) {}
      }

      // Cache this area page for offline navigation
      const pageCache = await caches.open("app-v1")
      const pageResponse = await fetch(window.location.pathname)
      await pageCache.put(window.location.pathname, pageResponse)

      const state = {
        downloadedAt: new Date().toISOString(),
        topoCount: cachedUrls.length,
        cachedUrls
      }
      localStorage.setItem(this.storageKey, JSON.stringify(state))

      this.progressTarget.classList.add("hidden")
      this.showSaved(state)
    } catch (_) {
      this.buttonTarget.disabled = false
      alert("Download failed. Check your connection and try again.")
    }
  }

  async clear() {
    const state = this.savedState
    if (state?.cachedUrls) {
      const cache = await caches.open("topos-v1")
      await Promise.all(state.cachedUrls.map(url => cache.delete(url)))
    }
    localStorage.removeItem(this.storageKey)

    this.statusTarget.classList.add("hidden")
    this.buttonTarget.disabled = false
    this.buttonTarget.textContent = "Save for offline"
  }

  showSaved(state) {
    const date = new Date(state.downloadedAt).toLocaleDateString()
    this.buttonTarget.disabled = true
    this.buttonTarget.textContent = "Saved"
    this.statusTarget.innerHTML =
      `${state.topoCount} photos saved (${date}). ` +
      `<a href="#" data-action="click->offline-download#clear" class="underline">Remove</a>`
    this.statusTarget.classList.remove("hidden")
  }

  get storageKey() {
    return `offline_area_${this.slugValue}`
  }

  get savedState() {
    const stored = localStorage.getItem(this.storageKey)
    return stored ? JSON.parse(stored) : null
  }
}
