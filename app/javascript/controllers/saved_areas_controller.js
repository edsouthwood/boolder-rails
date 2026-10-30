import { Controller } from "@hotwired/stimulus"
import { offlineSupported, savedAreas, isOutdated } from "offline_areas"

// Lists the areas saved for offline use so the home page — the installed app's start
// screen — leads straight to them, with or without a signal, and flags ones that have
// changed since they were saved (`versions`: { slug => current offline version },
// rendered by the server). Hidden when nothing is saved.
// public/service-worker.js renders a similar list on its "You're offline" page.
export default class extends Controller {
  static targets = ["list"]
  static values = { versions: Object }

  connect() {
    if (!offlineSupported()) return
    const areas = savedAreas()
    if (areas.length === 0) return

    this.listTarget.replaceChildren(...areas.map(area => {
      const li = document.createElement("li")
      const link = document.createElement("a")
      link.href = area.path
      link.className = "text-granite font-medium hover:underline"
      link.textContent = area.name
      li.append(link)
      if (area.downloadedAt) {
        const date = document.createElement("span")
        date.className = "text-muted text-sm ml-2"
        date.textContent = `saved ${new Date(area.downloadedAt).toLocaleDateString()}`
        li.append(date)
      }
      if (navigator.onLine && isOutdated(area, this.versionsValue[area.slug])) {
        const badge = document.createElement("span")
        badge.className = "text-amber-600 text-sm ml-2"
        badge.textContent = "update available"
        li.append(badge)
      }
      return li
    }))
    this.element.classList.remove("hidden")
  }
}
