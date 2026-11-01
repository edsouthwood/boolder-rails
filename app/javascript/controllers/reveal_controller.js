import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['item']
  static classes = ['hidden']

  connect () {
    this.class = this.hasHiddenClass ? this.hiddenClass : 'hidden'
  }

  toggle (event) {
    event?.preventDefault() // the trigger may be an href="#" link
    this.itemTargets.forEach(item => {
      item.classList.toggle(this.class)
    })
  }

  show () {
    this.itemTargets.forEach(item => {
      item.classList.remove(this.class)
    })
  }

  hide () {
    this.itemTargets.forEach(item => {
      item.classList.add(this.class)
    })
  }
}