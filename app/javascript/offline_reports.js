// "Report a mistake" with or without a connection. A report that can't be sent is kept
// in localStorage and sent later from any page (application.js calls
// flushQueuedReports on every page load and when the device comes back online).
//
// Every send — immediate or queued — first loads a fresh copy of the report form: the
// spam checks (invisible_captcha) need a session timestamp at least
// CAPTCHA_THRESHOLD_MS old and the spinner/CSRF tokens of a form this session
// actually rendered, so replaying a stale or cached form would be silently dropped
// as spam. The post asks for JSON so success, validation errors and spam rejection
// can be told apart (HTML answers all three with a redirect).

const QUEUE_KEY = "queued_reports"
// invisible_captcha's timestamp_threshold is 4 s; wait a little longer.
const CAPTCHA_THRESHOLD_MS = 4500
const FETCH_TIMEOUT_MS = 10000

// Network trouble (or a throttled 429): keep the report and retry later.
export class RetryLater extends Error {}

export function queuedReports() {
  try {
    return JSON.parse(localStorage.getItem(QUEUE_KEY)) || []
  } catch (_) {
    return []
  }
}

function saveQueue(reports) {
  if (reports.length > 0) {
    localStorage.setItem(QUEUE_KEY, JSON.stringify(reports))
  } else {
    localStorage.removeItem(QUEUE_KEY)
  }
}

// `report`: { comment, name, email, problemId, problemLabel }
export function queueReport(report) {
  saveQueue([...queuedReports(), { ...report, queuedAt: new Date().toISOString() }])
}

// Sends one report. Resolves { ok: true } or { ok: false, errors: [...] } (rejected —
// retrying won't help); throws RetryLater when the server can't be reached.
export async function sendReport(report, localeCode = "en") {
  const started = Date.now()
  let html
  try {
    const res = await fetch(`/${localeCode}/reports/new?sw-bypass=${started}`, {
      cache: "no-store", signal: AbortSignal.timeout(FETCH_TIMEOUT_MS)
    })
    if (!res.ok) throw new RetryLater(`report form: ${res.status}`)
    html = await res.text()
  } catch (error) {
    throw error instanceof RetryLater ? error : new RetryLater(error.message)
  }

  const form = new DOMParser().parseFromString(html, "text/html").querySelector("form[data-report-form-target='form']")
  if (!form) throw new RetryLater("report form not found")

  // The fresh form's own fields (CSRF token, spinner, empty honeypot), then the report.
  const body = new FormData()
  form.querySelectorAll("input[name], textarea[name]").forEach(field => {
    if (field.type !== "submit") body.append(field.name, field.value)
  })
  body.set("contribution[comment]", report.comment || "")
  body.set("contribution[contributor_name]", report.name || "")
  body.set("contribution[contributor_email]", report.email || "")
  body.set("contribution[problem_id]", report.problemId || "")

  const wait = CAPTCHA_THRESHOLD_MS - (Date.now() - started)
  if (wait > 0) await new Promise(resolve => setTimeout(resolve, wait))

  let res
  try {
    res = await fetch(form.getAttribute("action"), {
      method: "POST",
      body,
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS)
    })
  } catch (error) {
    throw new RetryLater(error.message)
  }
  if (res.status === 201) return { ok: true }
  if (res.status === 422) {
    const data = await res.json().catch(() => ({}))
    return { ok: false, errors: data.errors || ["rejected"] }
  }
  throw new RetryLater(`report post: ${res.status}`)
}

let flushing = false

// Sends queued reports, oldest first; stops at the first one that can't get through.
// Returns { sent, rejected } (rejected: refused by the server, so dropped).
export async function flushQueuedReports(localeCode = "en") {
  const sent = []
  const rejected = []
  if (flushing || queuedReports().length === 0 || navigator.onLine === false) return { sent, rejected }
  flushing = true
  try {
    for (const report of queuedReports()) {
      let result
      try {
        result = await sendReport(report, localeCode)
      } catch (error) {
        if (error instanceof RetryLater) break
        throw error
      }
      // Sent, or rejected for good (e.g. an invalid email): either way it's done.
      if (result.ok) {
        sent.push(report)
      } else {
        console.warn("Queued report rejected", result.errors, report)
        rejected.push(report)
      }
      saveQueue(queuedReports().filter(r => r.queuedAt !== report.queuedAt))
    }
  } finally {
    flushing = false
  }
  return { sent, rejected }
}

// A brief message pinned to the bottom of the screen.
export function showToast(text) {
  const toast = document.createElement("div")
  toast.setAttribute("role", "status")
  toast.className = "fixed inset-x-4 bottom-4 z-50 mx-auto max-w-md rounded-md bg-gray-900 px-4 py-3 text-sm text-white shadow-lg"
  toast.textContent = text
  document.body.append(toast)
  setTimeout(() => toast.remove(), 6000)
}
