import { Controller } from '@hotwired/stimulus'

// Closes a <details> menu when you click outside it or press Escape
export default class extends Controller {
  connect() {
    this.onClick = (event) => { if (!this.element.contains(event.target)) this.element.open = false }
    this.onKeydown = (event) => { if (event.key === 'Escape') this.element.open = false }
    document.addEventListener('click', this.onClick)
    document.addEventListener('keydown', this.onKeydown)
  }

  disconnect() {
    document.removeEventListener('click', this.onClick)
    document.removeEventListener('keydown', this.onKeydown)
  }
}
