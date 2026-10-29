import { Controller } from "@hotwired/stimulus"

// Lists the areas saved for offline use (from offline_download_controller's
// localStorage entries) so the home page — the installed app's start screen — leads
// straight to them, with or without a signal. Hidden when nothing is saved.
// public/service-worker.js renders the same list on its "You're offline" page.
export default class extends Controller {
  static targets = ["list"]

  connect() {
    const areas = savedAreas()
    if (areas.length === 0) return

    this.listTarget.replaceChildren(...areas.map(area => {
      const li = document.createElement("li")
      const link = document.createElement("a")
      link.href = area.path
      link.className = "text-emerald-600 font-medium hover:underline"
      link.textContent = area.name
      li.append(link)
      if (area.downloadedAt) {
        const date = document.createElement("span")
        date.className = "text-gray-400 text-sm ml-2"
        date.textContent = `saved ${new Date(area.downloadedAt).toLocaleDateString()}`
        li.append(date)
      }
      return li
    }))
    this.element.classList.remove("hidden")
  }
}

function savedAreas() {
  const locale = window.location.pathname.split("/")[1] || "en"
  const areas = []
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i)
    if (!key?.startsWith("offline_area_")) continue
    const slug = key.slice("offline_area_".length)
    let state = {}
    try { state = JSON.parse(localStorage.getItem(key)) || {} } catch (_) {}
    areas.push({
      // Saves made before name/path were stored fall back to the slug.
      name: state.name || slug.replace(/-/g, " ").replace(/\b\w/g, c => c.toUpperCase()),
      path: state.path || `/${locale}/dartmoor/${slug}`,
      downloadedAt: state.downloadedAt
    })
  }
  return areas.sort((a, b) => a.name.localeCompare(b.name))
}
