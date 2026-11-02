import { Controller } from '@hotwired/stimulus'

// Photo to the left / right on a problem page: the ← and → keys follow the arrow buttons
export default class extends Controller {
  static targets = ['left', 'right']

  key(event) {
    if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return
    if (event.target.closest('input, textarea, select, [contenteditable]')) return

    const link = event.key === 'ArrowLeft' ? this.leftTargets[0]
               : event.key === 'ArrowRight' ? this.rightTargets[0] : null
    if (!link) return

    event.preventDefault()
    link.click()
  }
}
