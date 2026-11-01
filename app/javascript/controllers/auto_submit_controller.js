import { Controller } from '@hotwired/stimulus'

// Submits the surrounding form when a field changes (filter dropdowns), in place of
// an inline onchange="this.form.submit()" that a Content-Security-Policy would block.
export default class extends Controller {
  submit() {
    this.element.requestSubmit ? this.element.requestSubmit() : this.element.submit()
  }
}
