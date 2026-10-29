import { Controller } from "@hotwired/stimulus"

// Offers "Install the app". Installing matters for offline use: Safari deletes a
// website's saved data after ~7 days without a visit, but not a home-screen app's.
// Android/desktop Chrome: a button that triggers the browser's install dialog, using
// the beforeinstallprompt event stashed by layouts/_pwa_head.html.erb. iPhone/iPad
// have no install API, so they get "Share → Add to Home Screen" instructions.
// Hidden when already running as the installed app.
export default class extends Controller {
  static targets = ["button", "iosHint"]

  connect() {
    if (isStandalone()) return

    this.showButton = this.showButton.bind(this)
    this.hide = this.hide.bind(this)
    window.addEventListener("installprompt-available", this.showButton)
    window.addEventListener("appinstalled", this.hide)

    if (window.deferredInstallPrompt) {
      this.showButton()
    } else if (isIos()) {
      this.iosHintTarget.classList.remove("hidden")
      this.element.classList.remove("hidden")
    }
  }

  disconnect() {
    window.removeEventListener("installprompt-available", this.showButton)
    window.removeEventListener("appinstalled", this.hide)
  }

  showButton() {
    this.buttonTarget.classList.remove("hidden")
    this.element.classList.remove("hidden")
  }

  hide() {
    this.element.classList.add("hidden")
  }

  async install() {
    const prompt = window.deferredInstallPrompt
    if (!prompt) return
    window.deferredInstallPrompt = null // single-use
    prompt.prompt()
    await prompt.userChoice
    this.hide()
  }
}

function isStandalone() {
  return window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true
}

// iPadOS reports itself as a Mac, so also check for a touch screen.
function isIos() {
  return /iPhone|iPad|iPod/.test(navigator.userAgent) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
}
