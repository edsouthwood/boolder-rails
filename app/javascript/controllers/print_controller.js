import { Controller } from '@hotwired/stimulus'

// "Print" button on the topo sheet
export default class extends Controller {
  print() {
    window.print()
  }
}
