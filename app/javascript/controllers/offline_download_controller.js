import { Controller } from "@hotwired/stimulus"
import {
  offlineSupported, savedState, isIntact, isOutdated, downloadArea, removeArea, locale
} from "offline_areas"

// The area page's "Save map & photos for offline" button. The download itself lives
// in offline_areas.js (shared with "My downloads"). `version` is the area's current
// offline version, rendered by the server, so a saved copy that's out of date offers
// "Update" without an extra request.
export default class extends Controller {
  static values = { url: String, slug: String, version: String }
  static targets = ["button", "progress", "count", "status"]

  connect() {
    if (!offlineSupported()) {
      this.element.classList.add("hidden")
      return
    }
    this.restoreSavedState()
  }

  async restoreSavedState() {
    const saved = savedState(this.slugValue)
    if (!saved) return

    if (await isIntact(saved)) {
      this.showSaved(saved)
    } else {
      await removeArea(this.slugValue)
      this.statusTarget.textContent =
        "The offline copy of this area is missing or outdated — please save it again."
      this.statusTarget.classList.remove("hidden")
    }
  }

  async download(event) {
    event?.preventDefault()
    this.buttonTarget.disabled = true
    this.statusTarget.classList.add("hidden")
    this.progressTarget.classList.remove("hidden")

    try {
      const state = await downloadArea(this.urlValue, text => { this.countTarget.textContent = text })
      this.progressTarget.classList.add("hidden")
      this.showSaved(state)
    } catch (error) {
      console.error("Offline download failed", error)
      this.progressTarget.classList.add("hidden")
      this.buttonTarget.disabled = false
      alert("Download failed. Check your connection and try again.")
    }
  }

  async clear(event) {
    event?.preventDefault()
    await removeArea(this.slugValue)

    this.statusTarget.classList.add("hidden")
    this.buttonTarget.disabled = false
    this.buttonTarget.textContent = "Save map & photos for offline"
  }

  showSaved(state) {
    const date = new Date(state.downloadedAt).toLocaleDateString()
    const outdated = navigator.onLine && isOutdated(state, this.versionValue)
    this.buttonTarget.disabled = true
    this.buttonTarget.textContent = "Saved"

    const warning = state.failedCount > 0
      ? ` <span class="text-amber-600">${state.failedCount} file${state.failedCount === 1 ? "" : "s"} failed to download — try saving again on a better connection.</span> ` +
        `<a href="/${locale()}/offline-status" class="underline">Details</a> ·`
      : ""
    const update = outdated
      ? ` <span class="text-amber-600">This area has changed since you saved it.</span> ` +
        `<a href="#" data-action="click->offline-download#download" class="underline text-emerald-700 font-medium">Update</a> · `
      : " "
    this.statusTarget.innerHTML =
      `Map & ${state.topoCount} photos saved (${date}).${warning}${update}` +
      `<a href="#" data-action="click->offline-download#clear" class="underline">Remove</a> · ` +
      `<a href="/${locale()}/downloads" class="underline">All downloads</a>`
    this.statusTarget.classList.remove("hidden")
  }
}
