import { Controller } from '@hotwired/stimulus'

// "What do you climb?" on the areas-by-level page: pick one or more levels and the crags
// re-sort by how many problems they have at those levels, each showing that number. The
// choice is remembered in this browser only (a convenience: the page works without it).
export default class extends Controller {
  static targets = ['button', 'clear', 'hint', 'list', 'row', 'heading', 'match']
  static values = { match: String }
  static STORAGE_KEY = 'crag-levels'

  connect() {
    this.selected = new Set(this.load())
    this.update()
  }

  toggle(event) {
    const level = Number(event.currentTarget.dataset.level)
    this.selected.has(level) ? this.selected.delete(level) : this.selected.add(level)
    this.save()
    this.update()
  }

  clear() {
    this.selected.clear()
    this.save()
    this.update()
  }

  update() {
    const picked = this.selected.size > 0

    this.buttonTargets.forEach((button) => {
      button.setAttribute('aria-pressed', String(this.selected.has(Number(button.dataset.level))))
    })
    this.clearTarget.classList.toggle('hidden', !picked)
    this.hintTarget.classList.toggle('hidden', picked)
    this.headingTargets.forEach((heading) => this.mark(heading, picked))

    const rows = this.rowTargets.map((row) => {
      const counts = JSON.parse(row.dataset.counts)
      const atLevel = [...this.selected].reduce((sum, level) => sum + (counts[level - 1] || 0), 0)
      const match = row.querySelector('[data-crag-levels-target="match"]')
      match.textContent = this.matchValue.replace('{n}', atLevel)
      match.classList.toggle('hidden', !picked)
      row.classList.toggle('opacity-50', picked && atLevel === 0)
      row.querySelectorAll('[data-level]').forEach((cell) => this.mark(cell, picked))
      return { row, atLevel, total: Number(row.dataset.total), index: Number(row.dataset.index) }
    })

    // Most at the chosen levels first (then the bigger crag); with nothing chosen, the
    // server's order (most problems first)
    rows.sort((a, b) => picked ? (b.atLevel - a.atLevel || b.total - a.total || a.index - b.index) : a.index - b.index)
    rows.forEach(({ row }) => this.listTarget.appendChild(row))
  }

  // Highlights a level's column when that level is chosen
  mark(element, picked) {
    const on = picked && this.selected.has(Number(element.dataset.level))
    element.classList.toggle('bg-gray-100', on)
    element.classList.toggle('font-bold', on)
  }

  load() {
    try {
      const levels = JSON.parse(localStorage.getItem(this.constructor.STORAGE_KEY) || '[]')
      return Array.isArray(levels) ? levels.filter((l) => Number.isInteger(l) && l >= 1 && l <= 8) : []
    } catch (_e) {
      return []
    }
  }

  save() {
    try {
      localStorage.setItem(this.constructor.STORAGE_KEY, JSON.stringify([...this.selected]))
    } catch (_e) {
      // Private browsing or storage blocked: the choice just isn't remembered
    }
  }
}
