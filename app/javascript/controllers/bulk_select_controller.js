import { Controller } from '@hotwired/stimulus'

// Toggles a set of row checkboxes from a single "select all" checkbox, and shows the
// bulk-action bar only when at least one row is selected.
export default class extends Controller {
  static targets = ['checkbox', 'all', 'bar', 'count']

  toggleAll() {
    this.checkboxTargets.forEach((c) => { c.checked = this.allTarget.checked })
    this.refresh()
  }

  refresh() {
    const selected = this.checkboxTargets.filter((c) => c.checked).length
    if (this.hasCountTarget) this.countTarget.textContent = selected
    if (this.hasBarTarget) this.barTarget.classList.toggle('hidden', selected === 0)
  }
}
