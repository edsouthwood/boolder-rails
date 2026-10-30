// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"
import { flushQueuedReports, showToast } from "offline_reports"

// HTTP Basic Auth dialogs only fire for full browser navigations, not fetch().
// Force a real navigation for any /admin path so the auth dialog appears correctly.
document.addEventListener('turbo:before-visit', function(event) {
  if (new URL(event.detail.url).pathname.startsWith('/admin')) {
    event.preventDefault()
    window.location.href = event.detail.url
  }
})
// Send problem reports written without a connection (offline_reports.js) as soon as
// any page loads with one, or the device comes back online.

async function sendQueuedReports() {
  const locale = window.location.pathname.split("/")[1] || "en"
  const { sent, rejected } = await flushQueuedReports(/^[a-z]{2}$/.test(locale) ? locale : "en")
  if (sent.length > 0) {
    showToast(sent.length === 1
      ? `Your saved report${sent[0].problemLabel ? ` about ${sent[0].problemLabel}` : ""} has been sent. Thank you!`
      : `Your ${sent.length} saved reports have been sent. Thank you!`)
  }
  if (rejected.length > 0) {
    showToast(`${rejected.length === 1 ? "A saved report" : `${rejected.length} saved reports`} couldn't be sent (rejected by the server).`)
  }
}
document.addEventListener("turbo:load", sendQueuedReports)
window.addEventListener("online", sendQueuedReports)
