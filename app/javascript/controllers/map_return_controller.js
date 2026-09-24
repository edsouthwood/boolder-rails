import { Controller } from '@hotwired/stimulus'

// Remembers the map viewport for the rest of the tab, so the control survives a hop
// to a variant problem page (which carries no fragment of its own).
const STORAGE_KEY = 'boolder.mapReturn'

// "Back to the map" — returns the user to the exact zoom/centre they left.
//
// The map stamps its viewport onto the problem link as
// `#map=<zoom>/<lat>/<lng>[/<bearing>[/<pitch>]]` (mapbox_controller#problemPopupHtml).
// The map itself is built with `hash: true`, which parses only the BARE
// `#<zoom>/<lat>/<lng>` form, so this controller strips the `map=` prefix when building
// the return URL. The target is always the bare /:locale/map: any slug or ?pid= makes
// MapController set bounds/problem values, and mapbox_controller#centerMap then flies
// over the hash.
export default class extends Controller {
  static targets = ['back', 'seeOnMap', 'seeOnMapLabel']
  static values = { mapPath: String, backLabel: String }

  connect() {
    const state = this.readState()
    if (!state) return

    const href = `${this.mapPathValue}#${state.hash}`

    if (this.hasBackTarget) {
      this.backTarget.href = href
      this.backTarget.classList.remove('hidden')
    }

    // Only relabel "See on the map" when *this* page was opened from the map. On a
    // variant page (storage-only state) that link should keep pointing at its own
    // problem; the breadcrumb control covers "take me back".
    if (state.fromFragment && this.hasSeeOnMapTarget) {
      this.seeOnMapTarget.href = href
      this.seeOnMapTarget.setAttribute('data-turbo', 'false')
      if (this.hasSeeOnMapLabelTarget) this.seeOnMapLabelTarget.textContent = this.backLabelValue
    }
  }

  readState() {
    const fromFragment = this.parse(window.location.hash.replace(/^#/, ''))
    if (fromFragment) {
      try { sessionStorage.setItem(STORAGE_KEY, fromFragment) } catch (_) {}
      return { hash: fromFragment, fromFragment: true }
    }

    let stored = null
    try { stored = sessionStorage.getItem(STORAGE_KEY) } catch (_) {}
    const valid = this.parse(stored ? `map=${stored}` : null)
    return valid ? { hash: valid, fromFragment: false } : null
  }

  // "map=<zoom>/<lat>/<lng>[/<bearing>[/<pitch>]]" -> the bare MapLibre hash body, or
  // null. Validated strictly: the result is interpolated into an href and then fed to
  // map.jumpTo().
  parse(raw) {
    const m = /^map=([-0-9./]+)$/.exec(raw || '')
    if (!m) return null

    const parts = m[1].split('/')
    if (parts.length < 3 || parts.length > 5) return null

    const nums = parts.map(Number)
    if (nums.some(n => !Number.isFinite(n))) return null

    const [zoom, lat, lng] = nums
    if (zoom < 0 || zoom > 24) return null
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null

    return m[1]
  }
}
