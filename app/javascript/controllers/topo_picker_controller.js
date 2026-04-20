import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['thumbnail', 'topoIdField', 'preview', 'previewImage', 'submitBtn', 'hint']

  select(event) {
    const el = event.currentTarget
    const id = el.dataset.topoId

    // Toggle off if already selected
    if (this.topoIdFieldTarget.value === id) {
      this.deselect()
      return
    }

    // Highlight selected thumbnail
    this.thumbnailTargets.forEach(t => t.classList.remove('border-emerald-500', 'border-2'))
    el.classList.add('border-emerald-500', 'border-2')

    // Populate hidden field
    this.topoIdFieldTarget.value = id

    // Show preview
    this.previewImageTarget.src = el.dataset.mediumUrl
    this.previewTarget.classList.remove('hidden')

    // Update hint + enable submit
    this.hintTarget.textContent = `Topo #${id} selected`
    this.submitBtnTarget.disabled = false
  }

  deselect() {
    this.thumbnailTargets.forEach(t => t.classList.remove('border-emerald-500', 'border-2'))
    this.topoIdFieldTarget.value = ''
    this.previewTarget.classList.add('hidden')
    this.previewImageTarget.src = ''
    this.hintTarget.textContent = 'Click a thumbnail to select'
    this.submitBtnTarget.disabled = true
  }

  connect() {
    // Disable submit until a topo is selected
    if (this.hasSubmitBtnTarget) {
      this.submitBtnTarget.disabled = true
    }
  }
}
