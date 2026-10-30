import { Controller } from "@hotwired/stimulus"
import { sendReport, queueReport, queuedReports, RetryLater } from "offline_reports"
import { locale } from "offline_areas"

// "Report a mistake" form. Sends via offline_reports.js; with no connection the
// report is kept on the phone and sent automatically later. Offline, this page is the
// copy saved with an area (/reports/new without ?problem_id), so the problem it's
// about is filled in here from the URL and the saved map data.
export default class extends Controller {
  static targets = ["form", "comment", "problemId", "about", "aboutName", "aboutArea", "status", "queued"]

  connect() {
    this.fillProblemFromUrl()
    this.showQueued()
  }

  async fillProblemFromUrl() {
    const problemId = new URLSearchParams(window.location.search).get("problem_id")
    if (!problemId || this.problemIdTarget.value === problemId) return
    this.problemIdTarget.value = problemId
    this.aboutNameTarget.textContent = `problem #${problemId}`
    this.aboutAreaTarget.textContent = ""
    this.aboutTarget.classList.remove("hidden")

    const cached = "caches" in window && await caches.match(`/${locale()}/map-data.geojson`).catch(() => null)
    if (!cached) return
    const feature = ((await cached.json()).features || []).find(f => String(f.properties?.id) === problemId)
    if (!feature) return
    this.aboutNameTarget.textContent = [feature.properties.name, feature.properties.grade].filter(Boolean).join(" ")
    this.aboutAreaTarget.textContent = feature.properties.areaName || ""
  }

  showQueued() {
    const count = queuedReports().length
    this.queuedTarget.textContent = count === 1
      ? "1 report is saved on this phone, waiting for a connection to send."
      : `${count} reports are saved on this phone, waiting for a connection to send.`
    this.queuedTarget.classList.toggle("hidden", count === 0)
  }

  async submit(event) {
    event.preventDefault()
    if (this.sending) return
    const data = new FormData(this.formTarget)
    const report = {
      comment: data.get("contribution[comment]"),
      name: data.get("contribution[contributor_name]"),
      email: data.get("contribution[contributor_email]"),
      problemId: data.get("contribution[problem_id]"),
      problemLabel: this.aboutTarget.classList.contains("hidden") ? "" : this.aboutNameTarget.textContent
    }

    this.sending = true
    this.setBusy(true)
    this.setStatus("Sending…", "text-gray-500")
    try {
      const result = await sendReport(report, locale())
      if (result.ok) {
        // The server set the "Thank you" flash for the next page.
        window.location.href = `/${locale()}/contribute`
        return
      }
      this.setStatus(`Couldn't send: ${result.errors.join(", ")}`, "text-red-600")
    } catch (error) {
      if (!(error instanceof RetryLater)) throw error
      queueReport(report)
      this.commentTarget.value = ""
      this.showQueued()
      this.setStatus("No connection — your report is saved on this phone and will be sent automatically when you're back online.", "text-amber-700")
    } finally {
      this.sending = false
      this.setBusy(false)
    }
  }

  setBusy(busy) {
    this.formTarget.querySelectorAll("[type=submit]").forEach(button => { button.disabled = busy })
  }

  setStatus(text, colour) {
    this.statusTarget.textContent = text
    this.statusTarget.className = `mt-4 px-4 sm:px-0 text-sm text-right ${colour}`
  }
}
