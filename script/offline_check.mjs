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
const AREA_URL = `${BASE_URL}/${LOCALE}/dartmoor/${SLUG}`
const MAP_URL = `${BASE_URL}/${LOCALE}/map/${SLUG}`
const STATUS_URL = `${BASE_URL}/${LOCALE}/offline-status`
const ARTIFACT_DIR = process.env.ARTIFACT_DIR || join(tmpdir(), "offline-check-artifacts")

// SwiftShader keeps WebGL (needed by MapLibre) working in headless Chromium.
const COMMON_ARGS = ["--enable-unsafe-swiftshader"]
// A dead proxy that even loopback traffic must go through = total offline,
// including service-worker-initiated fetches (unlike DevTools' offline toggle).
const OFFLINE_ARGS = [
  ...COMMON_ARGS,
  "--proxy-server=http://127.0.0.1:9",
  "--proxy-bypass-list=<-loopback>"
]

const failures = []
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
    failures.push(`Unexpected dialog: ${dialog.message()}`)
    await dialog.dismiss()
  })

  await page.goto(AREA_URL, { waitUntil: "load" })
  await page.waitForFunction(() => navigator.serviceWorker?.controller, null, { timeout: 15000 })
  console.log("  service worker is controlling the page")

  const button = page.locator('[data-offline-download-target="button"]')
  await button.click()
  await page.waitForFunction(
    () => document.querySelector('[data-offline-download-target="button"]')?.textContent.trim() === "Saved",
    null,
    { timeout: 480000 }
  )

  const state = await page.evaluate(slug => JSON.parse(localStorage.getItem(`offline_area_${slug}`)), SLUG)
  check(!!state, "download completed and saved its state")
  check(state.failedCount === 0, `no failed downloads (failedCount=${state?.failedCount})`)
  check(state.topoCount > 0, `topo photos cached (${state?.topoCount})`)
  check(state.problemUrls?.length > 0, `problem pages listed (${state?.problemUrls?.length})`)
  check(state.mapKeys?.length > 10, `map files tracked (${state?.mapKeys?.length})`)

  const problemUrl = BASE_URL + state.problemUrls[0]
  const topoUrl = state.cachedUrls[0]
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

  const problemResponse = await page.goto(problemUrl, { waitUntil: "load", timeout: 30000 })
  check(problemResponse.ok(), `problem page served offline (status ${problemResponse.status()})`)
  check(!(await page.content()).includes("You're offline"), "problem page is not the offline fallback")

  const topoOk = await page.evaluate(
    async url => { try { return (await fetch(url)).ok } catch { return false } },
    topoUrl
  )
  check(topoOk, "topo photo served offline")
  await page.screenshot({ path: join(ARTIFACT_DIR, "offline-problem.png"), fullPage: true })

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
