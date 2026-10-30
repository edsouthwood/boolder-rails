#!/usr/bin/env node
// End-to-end check of the offline feature ("Save map & photos for offline").
//
// Phase A (online):  opens an area page, clicks Save, waits for the download to
//                    finish and asserts nothing failed.
// Phase B (offline): relaunches the same browser profile behind a dead proxy —
//                    which blackholes ALL network traffic, including service
//                    worker fetches and localhost — then asserts the area map
//                    renders from cache (style + tiles + overlay served by the
//                    service worker), a problem page loads, a topo image loads,
//                    and the /offline-status page reports the area as complete.
//
// Usage:
//   bin/rails server                          # in another terminal
//   node script/offline_check.mjs [areaSlug]  # default slug: Smallacomberocks
//
// Env: BASE_URL (default http://localhost:3000), LOCALE (default en).
// REPORT_SEND=1 also checks that a report queued offline is sent once back online —
// this creates a real report and emails staff, so don't set it against production.
// Needs the `playwright` npm package resolvable (e.g. `npm i -g playwright`,
// or NODE_PATH pointing at a node_modules that contains it) and its Chromium
// downloaded (`npx playwright install chromium`).

import { createRequire } from "module"
import { mkdtempSync, rmSync, mkdirSync } from "fs"
import { tmpdir } from "os"
import { join } from "path"

const require = createRequire(import.meta.url)
const { chromium } = require("playwright")

const BASE_URL = process.env.BASE_URL || "http://localhost:3000"
const LOCALE = process.env.LOCALE || "en"
const SLUG = process.argv[2] || "Smallacomberocks"
// A second area, ideally near the first (overlapping map tiles), saved and removed
// via "My downloads" to prove removal keeps files the first area still needs.
const SECOND_SLUG = process.argv[3] || "belltor"
const DOWNLOADS_URL = `${BASE_URL}/${LOCALE}/downloads`
const AREA_URL = `${BASE_URL}/${LOCALE}/dartmoor/${SLUG}`
const MAP_URL = `${BASE_URL}/${LOCALE}/map/${SLUG}`
const STATUS_URL = `${BASE_URL}/${LOCALE}/offline-status`
const ARTIFACT_DIR = process.env.ARTIFACT_DIR || join(tmpdir(), "offline-check-artifacts")

// SwiftShader keeps WebGL (needed by MapLibre) working in headless Chromium.
// EXTRA_CHROMIUM_ARGS: space-separated extra flags, e.g. a host-resolver-rules
// mapping when checking production from the server itself (hairpin NAT to the
// public IP fails in Chromium):
//   EXTRA_CHROMIUM_ARGS="--host-resolver-rules=MAP bowda.edsouthwood.com 127.0.0.1"
const EXTRA_ARGS = process.env.EXTRA_CHROMIUM_ARGS ? [process.env.EXTRA_CHROMIUM_ARGS] : []
const COMMON_ARGS = ["--enable-unsafe-swiftshader", ...EXTRA_ARGS]
// A dead proxy that even loopback traffic must go through = total offline,
// including service-worker-initiated fetches (unlike DevTools' offline toggle).
const OFFLINE_ARGS = [
  ...COMMON_ARGS,
  "--proxy-server=http://127.0.0.1:9",
  "--proxy-bypass-list=<-loopback>"
]

const failures = []
// Round-trips the map viewport: map -> problem page -> "Back to the map" -> map.
// Driven through the ?pid= deep link because that is the only deterministic way to get
// a popup without pixel-hunting a dot; showProblem() always flies to exactly zoom 20,
// so the expected hash is predictable.
async function checkViewportRoundTrip(page, label, pid, problemPath) {
  await page.goto(`${MAP_URL}?pid=${pid}`, { waitUntil: "load", timeout: 30000 })
  const link = page.locator(`.maplibregl-popup a[href^="${problemPath}#map="]`)
  await link.waitFor({ timeout: 25000 })

  const href = await link.getAttribute("href")
  check(await link.getAttribute("target") === null, `${label}: popup link opens in the same tab`)

  const body = (href.split("#map=")[1] || "")
  check(/^20\/-?\d+\.\d+\/-?\d+\.\d+(\/-?\d+(\.\d+)?){0,2}$/.test(body),
        `${label}: popup link carries the viewport (#map=${body})`)

  await link.click()
  // Turbo Drive handles this visit, so there is no document "load" event to wait on —
  // wait for the problem page's own control to be attached instead.
  const back = page.locator('[data-map-return-target="back"]')
  await back.waitFor({ state: "visible", timeout: 20000 })
    .then(() => check(true, `${label}: "Back to the map" control is shown`))
    .catch(() => check(false, `${label}: "Back to the map" control is shown`))
  check(page.url().endsWith(`#map=${body}`),
        `${label}: fragment survives to the problem page (${page.url().split("/").pop()})`)
  check((await back.getAttribute("href")).endsWith(`/${LOCALE}/map#${body}`),
        `${label}: back control targets the bare map with the bare hash`)
  check((await page.textContent('[data-map-return-target="seeOnMapLabel"]')).trim() === "Back to the map",
        `${label}: "See on the map" is relabelled`)

  await back.click()
  await page.waitForSelector(".maplibregl-canvas", { timeout: 20000 })
  check(!(await page.content()).includes("You're offline"), `${label}: returned map is not the offline fallback`)
  // MapLibre rewrites the canonical hash on the moveend its own jumpTo(hash) fires, so a
  // surviving zoom-20 hash proves the view was restored, not merely that a URL was typed.
  check(page.url().startsWith(`${BASE_URL}/${LOCALE}/map#20/`),
        `${label}: map restored the saved viewport (#${page.url().split("#")[1]})`)
}

// "My downloads": lists the saved area; saves and removes a second area without
// breaking the first; flags an outdated save and updates it.
async function checkDownloadsPage(page, state) {
  const row = slug => `li[data-slug="${slug}"]`
  const allPresent = async keys => page.evaluate(async urls => {
    for (const url of urls) if (!(await caches.match(url, { ignoreVary: true }))) return url
    return null
  }, keys)

  await page.goto(DOWNLOADS_URL, { waitUntil: "load" })
  await page.waitForSelector(`${row(SLUG)} .size:not(:empty)`, { timeout: 30000 })
    .then(() => check(true, "downloads: saved area listed with its size"))
    .catch(() => check(false, "downloads: saved area listed with its size"))
  check(!(await page.textContent(row(SLUG))).includes("Update available"), "downloads: fresh save is up to date")

  await page.click(`${row(SECOND_SLUG)} button[data-action$="#save"]`)
  await page.waitForFunction(s => !!localStorage.getItem(`offline_area_${s}`), SECOND_SLUG, { timeout: 300000 })
  await page.waitForSelector(`${row(SECOND_SLUG)} button[data-action$="#remove"]:not([disabled])`, { timeout: 30000 })
  check(true, `downloads: saved a second area (${SECOND_SLUG})`)

  await page.click(`${row(SECOND_SLUG)} button[data-action$="#remove"]`)
  await page.waitForFunction(s => !localStorage.getItem(`offline_area_${s}`), SECOND_SLUG, { timeout: 30000 })
  const missing = await allPresent([...state.mapKeys, ...state.cachedUrls, ...state.problemUrls])
  check(missing === null, `downloads: removing ${SECOND_SLUG} kept every file ${SLUG} needs${missing ? ` (missing ${missing})` : ""}`)

  // Pretend the saved copy is from an older version of the area.
  await page.evaluate(s => {
    const key = `offline_area_${s}`
    localStorage.setItem(key, JSON.stringify({ ...JSON.parse(localStorage.getItem(key)), version: "outdated" }))
  }, SLUG)
  await page.reload({ waitUntil: "load" })
  check((await page.textContent(row(SLUG))).includes("Update available"), "downloads: outdated save shows Update available")
  await page.click(`${row(SLUG)} button[data-action$="#save"]`)
  await page.waitForFunction(s => JSON.parse(localStorage.getItem(`offline_area_${s}`)).version !== "outdated", SLUG, { timeout: 300000 })
  await page.waitForSelector(`${row(SLUG)} .size:not(:empty)`, { timeout: 30000 }).catch(() => {})
  const updated = await page.evaluate(s => JSON.parse(localStorage.getItem(`offline_area_${s}`)), SLUG)
  check(!(await page.textContent(row(SLUG))).includes("Update available") && updated.failedCount === 0,
    `downloads: Update refreshed the area (failedCount=${updated.failedCount})`)
  Object.assign(state, updated)
}

// Search with no connection: matches come from the saved map data, and tapping one
// opens the saved problem page.
async function checkOfflineSearch(page, state) {
  const problemPath = state.problemUrls[0]
  const name = await page.evaluate(async path => {
    const cached = await caches.match(`/${location.pathname.split("/")[1]}/map-data.geojson`)
    const feature = cached && (await cached.json()).features.find(f => f.properties.path === path)
    return feature?.properties.name
  }, problemPath)
  check(!!name, `offline search: saved map data has the problem (${name})`)

  const search = async query => {
    await page.locator('[data-action="click->search#openModal"]:visible').first().click()
    await page.fill("#search-input", query)
    await page.waitForSelector('[data-search-target="offlineNote"]:not(.hidden)', { timeout: 15000 })
  }

  await search(name)
  const result = page.locator('[data-search-target="searchResults"] li', { hasText: name }).first()
  check(await result.count() === 1, "offline search: finds a saved problem by name")
  check((await page.textContent('[data-search-target="offlineNote"]')).includes("saved areas"),
    "offline search: says results come from saved areas")
  await result.click()
  await page.waitForURL(url => url.pathname === problemPath, { timeout: 15000 })
    .then(() => check(true, "offline search: result opens the problem page"))
    .catch(() => check(false, `offline search: result opens the problem page (at ${page.url()})`))
  check(!(await page.content()).includes("You're offline"), "offline search: problem page is the saved copy")

  await page.goto(`${BASE_URL}/${LOCALE}`, { waitUntil: "load", timeout: 30000 })
  await search("zzqxv nothing")
  check((await page.textContent('[data-search-target="offlineNote"]')).includes("no matches"),
    "offline search: reports no matches")
}

// "Report a mistake" from a saved problem page with no connection: the saved form
// opens, knows the problem, and keeps the report on the phone.
async function checkOfflineReport(page, state) {
  await page.goto(BASE_URL + state.problemUrls[0], { waitUntil: "load", timeout: 30000 })
  const link = page.locator('a[href*="/reports/new?problem_id="]')
  check(await link.count() === 1, "offline report: problem page links Report a mistake")
  await link.click()
  await page.waitForSelector('[data-controller="report-form"]', { timeout: 15000 })
    .then(() => check(true, "offline report: saved form opens offline"))
    .catch(() => check(false, "offline report: saved form opens offline"))
  await page.waitForFunction(
    () => !document.querySelector('[data-report-form-target="about"]').classList.contains("hidden") &&
      !document.querySelector('[data-report-form-target="aboutName"]').textContent.startsWith("problem #"),
    null, { timeout: 10000 }
  ).then(() => check(true, "offline report: form names the problem from saved data"))
    .catch(() => check(false, "offline report: form names the problem from saved data"))

  await page.fill('[data-report-form-target="comment"]', "offline_check: test report, please ignore")
  await page.click('[data-report-form-target="form"] [type=submit]')
  await page.waitForFunction(() => (localStorage.getItem("queued_reports") || "").includes("offline_check"), null, { timeout: 30000 })
    .then(() => check(true, "offline report: kept on the phone"))
    .catch(() => check(false, "offline report: kept on the phone"))
  check((await page.textContent('[data-report-form-target="status"]')).includes("saved on this phone"),
    "offline report: tells the user it will be sent later")
}

function check(ok, label) {
  console.log(`  ${ok ? "PASS" : "FAIL"}  ${label}`)
  if (!ok) failures.push(label)
  return ok
}

const profileDir = mkdtempSync(join(tmpdir(), "offline-check-profile-"))
mkdirSync(ARTIFACT_DIR, { recursive: true })

try {
  // ---------- Phase A: save the area for offline ----------
  console.log(`\nPhase A (online): saving ${AREA_URL}`)
  let context = await chromium.launchPersistentContext(profileDir, { headless: true, args: COMMON_ARGS })
  let page = context.pages()[0] || await context.newPage()
  page.on("dialog", async dialog => {
    // "My downloads" confirms removals; anything else (e.g. a failure alert) is a bug.
    if (dialog.type() === "confirm" && dialog.message().startsWith("Remove ")) return dialog.accept()
    failures.push(`Unexpected dialog: ${dialog.message()}`)
    await dialog.dismiss()
  })

  await page.goto(AREA_URL, { waitUntil: "load" })
  await page.waitForFunction(() => navigator.serviceWorker?.controller, null, { timeout: 15000 })
  console.log("  service worker is controlling the page")

  // Browse the map first, as a real visitor would: the service worker then caches the
  // page's no-cors (opaque) copies of MapLibre and es-module-shims, which a save must
  // cope with.
  await page.goto(MAP_URL, { waitUntil: "load" })
  await page.waitForSelector(".maplibregl-canvas", { timeout: 20000 }).catch(() => {})
  await page.goto(AREA_URL, { waitUntil: "load" })

  const button = page.locator('[data-offline-download-target="button"]')
  await button.click()
  await page.waitForFunction(
    () => document.querySelector('[data-offline-download-target="button"]')?.textContent.trim() === "Saved",
    null,
    { timeout: 480000 }
  )

  const state = await page.evaluate(slug => JSON.parse(localStorage.getItem(`offline_area_${slug}`)), SLUG)
  check(!!state, "download completed and saved its state")
  check(state.failedCount === 0, `no failed downloads (failedCount=${state?.failedCount})${state?.failedUrls?.length ? " " + state.failedUrls.join(", ") : ""}`)
  check(state.topoCount > 0, `topo photos cached (${state?.topoCount})`)
  check(state.problemUrls?.length > 0, `problem pages listed (${state?.problemUrls?.length})`)
  check(state.mapKeys?.length > 10, `map files tracked (${state?.mapKeys?.length})`)
  check(!!state.name && state.path === new URL(AREA_URL).pathname, `area name and page stored (${state?.name})`)
  const imageCount = await page.evaluate(async () => (await (await caches.open("images-v1")).keys()).length)
  check(imageCount > 0, `area/home page photos cached (${imageCount})`)

  const problemUrl = BASE_URL + state.problemUrls[0]
  const topoUrl = state.cachedUrls[0]
  const pid = (state.problemUrls[0].match(/\/(\d+)[^/]*$/) || [])[1]

  await checkViewportRoundTrip(page, "online", pid, state.problemUrls[0])
  await checkDownloadsPage(page, state)

  await context.close()

  // ---------- Phase B: everything must work with zero network ----------
  console.log(`\nPhase B (offline): reloading ${MAP_URL} behind a dead proxy`)
  context = await chromium.launchPersistentContext(profileDir, { headless: true, args: OFFLINE_ARGS })
  page = context.pages()[0] || await context.newPage()

  const served = { style: 0, tilejson: 0, tiles: 0, glyphs: 0, sprites: 0, overlay: 0 }
  page.on("response", res => {
    const url = res.url()
    if (!res.ok()) return
    if (url.includes("/styles/liberty")) served.style++
    else if (url.endsWith("/planet")) served.tilejson++
    else if (/\.(pbf|png)(\?|$)/.test(url) && url.includes("openfreemap") && !url.includes("/sprites/")) {
      url.includes("/fonts/") ? served.glyphs++ : served.tiles++
    }
    if (url.includes("/sprites/")) served.sprites++
    if (url.includes("map-data")) served.overlay++
  })

  const mapResponse = await page.goto(MAP_URL, { waitUntil: "load", timeout: 30000 })
  check(mapResponse.ok(), `map page served offline (status ${mapResponse.status()})`)
  check(!(await page.content()).includes("You're offline"), "map page is not the offline fallback")
  await page.waitForSelector(".maplibregl-canvas", { timeout: 20000 })
    .then(() => check(true, "MapLibre canvas created"))
    .catch(() => check(false, "MapLibre canvas created"))
  await page.waitForTimeout(8000) // let tiles/glyphs/sprites load from cache

  check(served.style > 0, "base map style served from cache")
  check(served.tilejson > 0, "TileJSON served from cache")
  check(served.tiles > 0, `map tiles served from cache (${served.tiles})`)
  check(served.glyphs > 0, `glyphs served from cache (${served.glyphs})`)
  check(served.sprites > 0, `sprites served from cache (${served.sprites})`)
  check(served.overlay > 0, "problem overlay geojson served from cache")
  await page.screenshot({ path: join(ARTIFACT_DIR, "offline-map.png") })

  // "See on the map" from a problem page: /en/map/<slug>?pid=<id>. The bare map
  // page is served from cache (ignoreSearch) and the pid resolved client-side.
  const pidResponse = await page.goto(`${MAP_URL}?pid=${pid}`, { waitUntil: "load", timeout: 30000 })
  check(pidResponse.ok(), `"See on the map" page served offline (status ${pidResponse.status()})`)
  check(!(await page.content()).includes("You're offline"), '"See on the map" is not the offline fallback')
  await page.waitForSelector(`.maplibregl-popup a[href^="${state.problemUrls[0]}#map="]`, { timeout: 25000 })
    .then(() => check(true, "problem popup opens offline from ?pid link"))
    .catch(() => check(false, "problem popup opens offline from ?pid link"))

  // The header "Map" link (bare /en/map) is pre-cached too.
  const bareMapResponse = await page.goto(`${BASE_URL}/${LOCALE}/map`, { waitUntil: "load", timeout: 30000 })
  check(bareMapResponse.ok(), `bare map page served offline (status ${bareMapResponse.status()})`)
  check(!(await page.content()).includes("You're offline"), "bare map page is not the offline fallback")

  await checkViewportRoundTrip(page, "offline", pid, state.problemUrls[0])

  const problemResponse = await page.goto(problemUrl, { waitUntil: "load", timeout: 30000 })
  check(problemResponse.ok(), `problem page served offline (status ${problemResponse.status()})`)
  check(!(await page.content()).includes("You're offline"), "problem page is not the offline fallback")

  const topoOk = await page.evaluate(
    async url => { try { return (await fetch(url)).ok } catch { return false } },
    topoUrl
  )
  check(topoOk, "topo photo served offline")
  await page.screenshot({ path: join(ARTIFACT_DIR, "offline-problem.png"), fullPage: true })

  // The installed app's start screen (manifest start_url) opens offline and lists
  // the saved area, with its cover photos served from cache.
  const homeImages = []
  const onHomeImage = res => {
    if (res.url().includes("/rails/active_storage/")) homeImages.push(res.ok())
  }
  page.on("response", onHomeImage)
  const homeResponse = await page.goto(`${BASE_URL}/${LOCALE}`, { waitUntil: "load", timeout: 30000 })
  check(homeResponse.ok(), `home page (app start screen) served offline (status ${homeResponse.status()})`)
  check(!(await page.content()).includes("You're offline"), "home page is not the offline fallback")
  await page.waitForSelector(`[data-saved-areas-target="list"] a[href="${state.path}"]`, { timeout: 10000 })
    .then(() => check(true, `home page lists the saved area (${state.name})`))
    .catch(() => check(false, `home page lists the saved area (${state.name})`))
  await page.waitForTimeout(1000)
  check(homeImages.length > 0 && homeImages.every(Boolean),
    `home page photos served from cache (${homeImages.filter(Boolean).length}/${homeImages.length})`)
  page.off("response", onHomeImage)
  await page.screenshot({ path: join(ARTIFACT_DIR, "offline-home.png"), fullPage: true })

  await checkOfflineSearch(page, state)

  // A page that was never saved gets the offline fallback, which links saved areas.
  await page.goto(`${BASE_URL}/${LOCALE}/never-saved-page`, { waitUntil: "load", timeout: 30000 })
  check((await page.content()).includes("You're offline"), "unsaved page shows the offline fallback")
  await page.waitForSelector(`#saved-list a[href="${state.path}"]`, { timeout: 5000 })
    .then(() => check(true, "offline fallback links the saved area"))
    .catch(() => check(false, "offline fallback links the saved area"))

  // "My downloads" works offline and lists only what's saved, with no save buttons.
  const downloadsResponse = await page.goto(DOWNLOADS_URL, { waitUntil: "load", timeout: 30000 })
  check(downloadsResponse.ok(), `downloads page served offline (status ${downloadsResponse.status()})`)
  await page.waitForSelector(`li[data-slug="${SLUG}"]`, { timeout: 10000 })
    .then(() => check(true, "downloads page lists the saved area offline"))
    .catch(() => check(false, "downloads page lists the saved area offline"))
  await page.waitForSelector('[data-offline-downloads-target="offlineNote"]:not(.hidden)', { timeout: 10000 })
    .then(() => check(true, "downloads page notices it's offline"))
    .catch(() => check(false, "downloads page notices it's offline"))
  check(await page.locator('button[data-action$="#save"]').count() === 0, "downloads page offers no saving while offline")
  check(await page.locator(`li[data-slug="${SECOND_SLUG}"]`).count() === 0, "downloads page hides unsaved areas while offline")

  await checkOfflineReport(page, state)

  const statusResponse = await page.goto(STATUS_URL, { waitUntil: "load", timeout: 30000 })
  check(statusResponse.ok(), `offline-status page served offline (status ${statusResponse.status()})`)
  await page.waitForFunction(
    () => document.querySelector('[data-offline-status-target="areas"]')?.textContent.includes("of"),
    null,
    { timeout: 15000 }
  ).catch(() => {})
  const statusText = await page.textContent("body")
  check(statusText.includes("Complete."), "offline-status reports the saved area as complete")
  await page.screenshot({ path: join(ARTIFACT_DIR, "offline-status.png"), fullPage: true })

  await context.close()

  // ---------- Phase C: back online, the queued report is sent ----------
  if (process.env.REPORT_SEND === "1") {
    console.log("\nPhase C (online again): sending the queued report")
    context = await chromium.launchPersistentContext(profileDir, { headless: true, args: COMMON_ARGS })
    page = context.pages()[0] || await context.newPage()
    await page.goto(`${BASE_URL}/${LOCALE}`, { waitUntil: "load" })
    await page.waitForFunction(() => !localStorage.getItem("queued_reports"), null, { timeout: 30000 })
      .then(() => check(true, "queued report sent once back online"))
      .catch(() => check(false, "queued report sent once back online"))
    await page.waitForSelector('[role="status"]', { timeout: 5000 })
      .then(async el => check((await el.textContent()).includes("has been sent"), "toast confirms the report was sent"))
      .catch(() => check(false, "toast confirms the report was sent"))
    await context.close()
  }
} finally {
  rmSync(profileDir, { recursive: true, force: true })
}

console.log(`\nScreenshots: ${ARTIFACT_DIR}`)
if (failures.length > 0) {
  console.log(`\n${failures.length} CHECK(S) FAILED:`)
  failures.forEach(f => console.log(`  - ${f}`))
  process.exit(1)
}
console.log("\nAll offline checks passed.")
