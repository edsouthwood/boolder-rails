import { Controller } from "@hotwired/stimulus"
import {
  offlineSupported, savedAreas, savedState, isOutdated, downloadArea, removeArea, areaSize, formatBytes,
  reachable
} from "offline_areas"

// "My downloads" (/[locale]/downloads): every published area with its offline state —
// save, update (when it changed since saving) or remove it, or save/update them all.
// `areas` comes from the server ([{ slug, name, version, problemCount, dataUrl,
// areaUrl }]); offline (no server reachable), only the areas saved on this device are
// listed and nothing can be saved.
export default class extends Controller {
  static values = { areas: Array }
  static targets = ["main", "unsupported", "offlineNote", "allButton", "storage", "progress", "list"]

  connect() {
    if (!offlineSupported()) {
      this.unsupportedTarget.classList.remove("hidden")
      return
    }
    this.busy = false
    this.online = navigator.onLine
    this.checkConnection = this.checkConnection.bind(this)
    window.addEventListener("online", this.checkConnection)
    window.addEventListener("offline", this.checkConnection)
    this.mainTarget.classList.remove("hidden")
    this.render()
    this.checkConnection()
  }

  disconnect() {
    window.removeEventListener("online", this.checkConnection)
    window.removeEventListener("offline", this.checkConnection)
  }

  async checkConnection() {
    this.online = await reachable()
    this.render()
  }

  // Server areas merged with anything saved that the server no longer lists.
  get rows() {
    const bySlug = new Map(this.areasValue.map(area => [area.slug, { ...area }]))
    for (const saved of savedAreas()) {
      if (!bySlug.has(saved.slug)) bySlug.set(saved.slug, { slug: saved.slug, name: saved.name, areaUrl: saved.path })
    }
    return [...bySlug.values()].map(area => {
      const state = savedState(area.slug)
      return { ...area, state, outdated: isOutdated(state, area.version) }
    })
  }

  render() {
    const online = this.online
    const rows = online ? this.rows : this.rows.filter(row => row.state)
    this.offlineNoteTarget.classList.toggle("hidden", online)

    const pending = rows.filter(row => row.dataUrl && (!row.state || row.outdated))
    const unsaved = pending.filter(row => !row.state).length
    this.allButtonTarget.classList.toggle("hidden", !online || pending.length === 0)
    this.allButtonTarget.disabled = this.busy
    this.allButtonTarget.textContent = unsaved > 0
      ? `Save all areas (${pending.length})`
      : `Update all (${pending.length})`

    this.listTarget.replaceChildren(...(rows.length > 0 ? rows.map(row => this.rowElement(row, online)) : [this.emptyElement()]))
    this.renderStorage()
    rows.filter(row => row.state).forEach(row => this.fillSize(row))
  }

  rowElement(row, online) {
    const li = document.createElement("li")
    li.className = "py-4 flex flex-wrap items-center justify-between gap-x-4 gap-y-2"
    li.dataset.slug = row.slug

    const info = document.createElement("div")
    const name = document.createElement("a")
    name.href = row.areaUrl
    name.className = "font-medium text-gray-900 hover:underline"
    name.textContent = row.name
    info.append(name)
    if (row.problemCount) info.append(element("span", "ml-2 text-sm text-gray-400", `${row.problemCount} problem${row.problemCount === 1 ? "" : "s"}`))

    const status = element("div", "text-sm text-gray-500")
    if (row.state) {
      status.append(`Saved ${new Date(row.state.downloadedAt).toLocaleDateString()}`)
      status.append(element("span", "size", ""))
      if (row.state.failedCount > 0) {
        status.append(element("span", "text-amber-600", ` · ${row.state.failedCount} files failed — update to retry`))
      }
      if (online && row.outdated) status.append(element("span", "text-amber-600 font-medium", " · Update available"))
    } else {
      status.textContent = "Not saved"
    }
    info.append(status)

    const actions = element("div", "flex items-center gap-x-3 text-sm")
    if (online && row.dataUrl && (!row.state || row.outdated || row.state.failedCount > 0)) {
      actions.append(this.button(row.state ? "Update" : "Save", "save", row.slug, true))
    }
    if (row.state) actions.append(this.button("Remove", "remove", row.slug, false))

    li.append(info, actions)
    return li
  }

  emptyElement() {
    return element("li", "py-4 text-sm text-gray-500",
      this.online ? "No areas to save yet." : "No areas are saved on this device.")
  }

  button(label, action, slug, primary) {
    const button = element("button", primary
      ? "rounded-md border border-granite px-3 py-1 font-medium text-granite-dark hover:bg-ground disabled:opacity-50"
      : "text-gray-500 underline hover:text-gray-700 disabled:opacity-50", label)
    button.type = "button"
    button.disabled = this.busy
    button.dataset.action = `offline-downloads#${action}`
    button.dataset.slug = slug
    return button
  }

  async fillSize(row) {
    const bytes = await areaSize(row.state)
    const span = this.listTarget.querySelector(`li[data-slug="${CSS.escape(row.slug)}"] .size`)
    if (span) span.textContent = ` · ${formatBytes(bytes)}`
  }

  async renderStorage() {
    if (!navigator.storage?.estimate) return
    const { usage } = await navigator.storage.estimate()
    const persisted = await navigator.storage.persisted?.()
    this.storageTarget.textContent = `Using ${formatBytes(usage)} on this device` +
      (persisted === false && savedAreas().length > 0 ? " · may be cleared by the browser — install the app to keep it" : "")
  }

  async save(event) {
    const row = this.rows.find(r => r.slug === event.currentTarget.dataset.slug)
    if (row) await this.run([row])
  }

  async downloadAll() {
    await this.run(this.rows.filter(row => row.dataUrl && (!row.state || row.outdated)))
  }

  async remove(event) {
    const slug = event.currentTarget.dataset.slug
    const row = this.rows.find(r => r.slug === slug)
    if (!confirm(`Remove ${row?.name || slug} from this device?`)) return
    this.busy = true
    this.render()
    try {
      await removeArea(slug)
    } finally {
      this.busy = false
      this.render()
    }
  }

  // Downloads areas one at a time, reporting progress; one failure doesn't stop the rest.
  async run(rows) {
    if (rows.length === 0 || this.busy) return
    this.busy = true
    this.render()
    this.progressTarget.classList.remove("hidden")
    const failed = []

    for (const [index, row] of rows.entries()) {
      const prefix = rows.length > 1 ? `${row.name} (${index + 1} of ${rows.length}): ` : `${row.name}: `
      try {
        await downloadArea(row.dataUrl, text => { this.progressTarget.textContent = prefix + text })
      } catch (error) {
        console.error("Offline download failed", row.slug, error)
        failed.push(row.name)
      }
    }

    this.busy = false
    if (failed.length > 0) this.online = await reachable()
    this.progressTarget.textContent = failed.length > 0
      ? `Couldn't download ${failed.join(", ")}. Check your connection and try again.`
      : rows.length > 1 ? `Done — ${rows.length} areas saved.` : `Done — ${rows[0].name} saved.`
    this.render()
  }
}

function element(tag, className, text) {
  const el = document.createElement(tag)
  if (className) el.className = className
  if (text !== undefined) el.textContent = text
  return el
}
