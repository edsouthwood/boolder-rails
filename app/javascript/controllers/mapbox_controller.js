// The public map: set-up, popups, clicks, grade filters and search hooks.
// Sources and layers live in map_layers.js.

import { Controller } from '@hotwired/stimulus'
import { addMapLayers } from 'map_layers'

// Base map style. Keep in sync with MAP_STYLE_URL in offline_download_controller.js,
// which pre-downloads this style's tiles/glyphs/sprites for offline use.
const MAP_STYLE_URL = 'https://tiles.openfreemap.org/styles/liberty'

export default class extends Controller {
  static targets = [ 
    "map", 
    "gradeRadioButton", "gradeMin", "gradeMax", "customGradePicker",
    "filterCounter", "filterIcon" 
  ]
  static values = {
    bounds: Object,
    problem: Object,
    locale: { type: String, default: 'en' },
    draft: { type: Boolean, default: false },
    contribute: { type: Boolean, default: false },
    contributeSource: String,
    mapDataSource: String,
    areaLabelsSource: String,
    // { colors: [[hex, [grades]], ...], unknown: hex, outline: hex } — rendered by
    // ProblemsHelper#grade_colors_json so the map, the problem lists, the topo
    // circles and the search results all share one grade palette.
    gradeColors: Object,
    // [[display grade, [stored grades it covers]], ...] in grade order, from
    // Problem.grades_matching — so filters catch both "4+" and legacy "4b+"
    gradeGroups: Array,
  }

  connect() {
    // maplibre-gl is a plain <script> from a CDN, so it is not part of the importmap
    // module graph and its execution order relative to this controller is not
    // guaranteed (es-module-shims loads async, and a warm HTTP cache changes the
    // interleaving). Wait for the loader's 'maplibre-ready' event instead of assuming
    // the global is already there — same guard as the admin/mapping map controllers.
    if (typeof maplibregl === 'undefined') {
      window.addEventListener('maplibre-ready', () => this.connect(), { once: true })
      return
    }
    if (this.map) return // guard against double-connect after maplibre-ready

    this.map = new maplibregl.Map({
      container: 'map',
      hash: true,
      style: MAP_STYLE_URL,
      bounds: [[-4.1, 50.45],[-3.7, 50.70]],
      padding: 5,
    });

    // The OpenFreeMap "liberty" style names its POI icons from the vector tile's
    // `class` field, but its sprite ships no icon for some of those names —
    // `gate` and `stile` are all over Dartmoor's OSM data. MapLibre then logs a
    // warning for every missing name on every map load. Register a transparent
    // 1x1 placeholder so the POI's label still draws (as it does today) and the
    // console stays readable.
    this.map.on('styleimagemissing', (e) => {
      if (this.map.hasImage(e.id)) return
      this.map.addImage(e.id, { width: 1, height: 1, data: new Uint8Array(4) })
    })

    this.addControls()

    this.map.on('load', () => {
      this.addLayers()
      this.centerMap()
      this.cleanHistory()
    });

    this.popup = null
    this.pendingPopup = null
    this.map.on('moveend', () => {
      if(this.popup != null) {
        if(this.pendingPopup) {
          this.popup.setHTML(this.problemPopupHtml(this.pendingPopup.problem, this.pendingPopup.name))
          this.pendingPopup = null
        }
        this.popup.addTo(this.map)
        this.stampReturnView(this.popup)
        this.popup = null
      }
    });

    this.setupClickEvents()

    this.displayGrades = this.gradeGroupsValue.map(([grade]) => grade)
    this.allGrades = this.gradeGroupsValue.flatMap(([, grades]) => grades)
  }

  disconnect() {
    if (this.map) {
      this.map.remove()
    }
  }

  addControls() {
    this.map.addControl(
      new maplibregl.ScaleControl({
        maxWidth: 100,
        unit: 'metric'
       })
    );

    this.map.addControl(
      new maplibregl.NavigationControl()
    );

    this.geolocate = new maplibregl.GeolocateControl({
      positionOptions: {
        enableHighAccuracy: true
      },
      trackUserLocation: true,
      showUserHeading: true
    });
    this.map.addControl(this.geolocate);
  }

  addLayers() {
    addMapLayers(this.map, {
      mapDataSource: this.hasMapDataSourceValue ? this.mapDataSourceValue : null,
      areaLabelsSource: this.hasAreaLabelsSourceValue ? this.areaLabelsSourceValue : null,
      contributeSource: this.contributeSourceValue,
      contribute: this.contributeValue,
      gradeColors: this.gradeColorsValue,
    })
  }

  centerMap() {
    if(this.hasBoundsValue) { 
      let bounds = this.boundsValue

      this.flyToBounds([[bounds.southWestLon, bounds.southWestLat], [bounds.northEastLon, bounds.northEastLat]])
    }

    if(this.hasProblemValue) {
      this.showProblem(this.problemValue)
    }
    else {
      // Offline, the service worker serves the cached bare map page for
      // "See on the map" links (?pid=...), so the server couldn't embed the
      // problem — resolve it from the (cached) map-data GeoJSON instead.
      this.resolveProblemFromPid().then(problem => {
        if(problem) this.showProblem(problem)
      })
    }
  }

  // MapLibre's own hash format (Hash#getHashString): coordinate precision is tied to
  // zoom so the string round-trips to the same pixel, and bearing/pitch are appended
  // only when non-zero — exactly what Hash#_onHashChange parses back. Computed from
  // the live map rather than scraped from location.hash, which is empty until the
  // first moveend.
  viewportHash() {
    const center = this.map.getCenter()
    const zoom = Math.round(this.map.getZoom() * 100) / 100
    const precision = Math.ceil((zoom * Math.LN2 + Math.log(512 / 360 / 0.5)) / Math.LN10)
    const m = Math.pow(10, precision)
    const lat = Math.round(center.lat * m) / m
    const lng = Math.round(center.lng * m) / m
    const bearing = this.map.getBearing()
    const pitch = this.map.getPitch()
    let hash = `${zoom}/${lat}/${lng}`
    if (bearing || pitch) hash += `/${Math.round(bearing * 10) / 10}`
    if (pitch) hash += `/${Math.round(pitch)}`
    return hash
  }

  // Link straight to the canonical problem page (no redirect hop) so it works offline,
  // carrying the viewport so the problem page can offer "Back to the map". The map
  // itself is built with `hash: true`, which only parses a BARE #zoom/lat/lng — hence
  // the `map=` prefix here, which map_return_controller strips when it builds the
  // return URL. Same tab: the browser Back button should work too.
  problemPopupHtml(problem, name) {
    return `<a href="${problem.path}#map=${this.viewportHash()}" data-problem-path="${problem.path}">${name || ""}</a>` +
           `<span class="text-gray-400 ml-1">${problem.grade}</span>`
  }

  // Refresh the viewport on the popup link at click time: the user may have panned
  // since the popup opened, and they should return to what they are looking at now.
  // No preventDefault — the browser reads href when it runs the default action, so
  // middle- and ctrl-click keep working.
  stampReturnView(popup) {
    const link = popup.getElement()?.querySelector('a[data-problem-path]')
    if (!link) return
    link.addEventListener('click', () => {
      link.href = `${link.dataset.problemPath}#map=${this.viewportHash()}`
    })
  }

  showProblem(problem) {
    this.map.flyTo({
      center: [problem.lon, problem.lat],
      zoom: 20,
      speed: 2
    });

    if(!this.contributeValue) {

      const coordinates = [problem.lon, problem.lat];
      const name = this.displayName(problem)
      // HTML is built by the 'moveend' handler above, not here: the flyTo hasn't run
      // yet, so viewportHash() would capture the pre-flight view.
      this.pendingPopup = { problem, name }

      // will be displayed thanks to the 'moveend' event code above
      this.popup = this.newPopup().setLngLat(coordinates)
    }
  }

  async resolveProblemFromPid() {
    const pid = new URLSearchParams(window.location.search).get('pid')
    if(!pid || !this.hasMapDataSourceValue) return null
    try {
      const res = await fetch(this.mapDataSourceValue)
      const geojson = await res.json()
      const feature = geojson.features.find(f =>
        f.geometry?.type === 'Point' && String(f.properties?.id) === pid
      )
      if(!feature) return null
      return {
        lon: feature.geometry.coordinates[0],
        lat: feature.geometry.coordinates[1],
        name: feature.properties.name,
        grade: feature.properties.grade,
        path: feature.properties.path
      }
    } catch(_) {
      return null
    }
  }

  cleanHistory() {
    this.map.on('movestart', () => {
      // we remove the arguments (like area_id or problem_id) because mapbox provides a hash (url fragment) to allow for friendly url sharing
      // TODO: replace url only when user does something (eg. moves, closes a modal)

      var url = ""
      if(this.contributeValue) {
        url = `/${this.localeValue}/mapping/map`
      }
      else {
        url = `/${this.localeValue}/map`
      }

      history.replaceState({} , '', url)
    });
  }

  setupClickEvents() {
    this.pointerOn('problems')
    this.map.on('click', 'problems', (e) => {
      const problem = e.features[0].properties
      const popup = this.openPopup(e.features[0].geometry.coordinates.slice(),
        this.problemPopupHtml(problem, this.displayName(problem)))
      this.stampReturnView(popup)
    })

    // Contribute mode: a dot per group of problems that need mapping
    const contributeLayers = ['contribute-problems', 'contribute-problems-texts']
    this.pointerOn(contributeLayers)
    this.map.on('click', contributeLayers, (e) => {
      const problems = JSON.parse(e.features[0].properties.problems)
      const html = problems.map(problem => `<div>
        <a href="/${this.localeValue}/mapping/problems/${problem.id}" target="_blank">${problem.name || ""}</a>
        <span class="text-gray-400 ml-1">${problem.grade}</span>
</div>`).join("")
      this.openPopup(e.features[0].geometry.coordinates.slice(), html)
    })

    const poisVisible = () => this.map.getZoom() >= 12
    this.pointerOn('pois', poisVisible)
    this.map.on('click', 'pois', (e) => {
      if (!poisVisible()) return
      this.openPopup(e.features[0].geometry.coordinates.slice(),
        `<a href="${e.features[0].properties.googleUrl}" target="_blank">See on Google</a>`)
    })

    // Zoomed out, clicking an area (or a cluster of them) flies to it
    const areasClickable = () => this.map.getZoom() < 15
    const clustersClickable = () => this.map.getZoom() <= 12
    const flyToArea = (e) => {
      const props = e.features[0].properties
      this.flyToBounds([[props.southWestLon, props.southWestLat], [props.northEastLon, props.northEastLat]])
    }
    for (const [layer, when] of [['areas', areasClickable], ['areas-circles', areasClickable], ['areas-hulls', areasClickable], ['clusters', clustersClickable]]) {
      this.pointerOn(layer, when)
      this.map.on('click', layer, (e) => { if (when()) flyToArea(e) })
    }
  }

  // Pointer cursor over a layer (or layers), only while `when()` holds
  pointerOn(layers, when = () => true) {
    this.map.on('mouseenter', layers, () => { if (when()) this.map.getCanvas().style.cursor = 'pointer' })
    this.map.on('mouseleave', layers, () => { if (when()) this.map.getCanvas().style.cursor = '' })
  }

  newPopup() {
    return new maplibregl.Popup({ closeButton: false, focusAfterOpen: false, offset: [0, -8] })
  }

  openPopup(coordinates, html) {
    return this.newPopup().setLngLat(coordinates).setHTML(html).addTo(this.map)
  }

  displayName(problem) {
    return (this.localeValue == 'en' && problem.nameEn) ? problem.nameEn : problem.name
  }

  flyToBounds(bounds) {

    var cameraOptions = this.map.cameraForBounds(
      bounds
      , 
      {
        padding: {top: 20, bottom:100, left: 20, right: 20}
      }
    );

    cameraOptions.zoom = Math.max(15, cameraOptions.zoom)
    cameraOptions.speed = 2

    this.map.flyTo(cameraOptions)
  }

  // =========================================================
  // TODO: move the filters logic into its own controller
  // =========================================================

  didSelectFilter(event) {
    this.gradeRadioButton = event.target.value

    if(this.gradeRadioButton == "custom") {
      this.customGradePickerTarget.classList.remove("hidden")
    }
    else {
      this.customGradePickerTarget.classList.add("hidden")
    }
  }

  applyFilters() {
    this.filterCounterTarget.classList.remove("hidden")
    this.filterIconTarget.classList.add("hidden")

    let grades
    const level = this.gradeRadioButton
    if (level == "beginner") {
      grades = this.gradesWhere(grade => parseInt(grade) <= 3)
    } else if (/^level\d$/.test(level || "")) {
      grades = this.gradesWhere(grade => grade[0] == level.slice(-1))
    } else if (level == "custom") {
      const min = this.displayGrades.indexOf(this.gradeMinTarget.value)
      const max = this.displayGrades.indexOf(this.gradeMaxTarget.value)
      grades = this.gradeGroupsValue.slice(min, max + 1).flatMap(([, grades]) => grades)
    } else {
      grades = this.allGrades
    }

    this.applyLayerFilter('problems', grades)
    this.applyLayerFilter('problems-texts', grades)
  }

  // Stored grades of every display grade passing the test
  gradesWhere(test) {
    return this.gradeGroupsValue.filter(([grade]) => test(grade)).flatMap(([, grades]) => grades)
  }

  clearFilters() {
    this.gradeRadioButton = null

    this.filterCounterTarget.classList.add("hidden")
    this.filterIconTarget.classList.remove("hidden")

    this.gradeRadioButtonTargets.forEach(item => {
      item.checked = false
    })

    this.applyLayerFilter('problems', this.allGrades)
    this.applyLayerFilter('problems-texts', this.allGrades)
  }

  applyLayerFilter(layer, grades) {
    if(!this.map.getLayer(layer)) return;
    this.map.setFilter(layer, [
      'match',
      ['get', 'grade'],
      grades,
      true,
      false
    ]);
  }

  didSelectGradeMin() {
    const indexMin = this.displayGrades.indexOf(this.gradeMinTarget.value)
    const indexMax = this.displayGrades.indexOf(this.gradeMaxTarget.value)
    this.gradeMaxTarget.value = this.displayGrades[Math.max(indexMin, indexMax)]
  }

  didSelectGradeMax() {
    const indexMin = this.displayGrades.indexOf(this.gradeMinTarget.value)
    const indexMax = this.displayGrades.indexOf(this.gradeMaxTarget.value)
    this.gradeMinTarget.value = this.displayGrades[Math.min(indexMin, indexMax)]
  }

  // =========================================================


  // =========================================================
  // Hooks coming from search_controller
  // =========================================================

  gotoproblem(event) {
    this.map.flyTo({
      center: [event.detail.lon, event.detail.lat],
      zoom: 20,
      speed: 2
    });

    const coordinates = [event.detail.lon, event.detail.lat];
    // The result's own path (when present) opens offline too; the redirect needs the server.
    const href = event.detail.path || `/${this.localeValue}/redirects/new?problem_id=${event.detail.id}`;
    const link = document.createElement("a");
    link.href = href;
    link.target = "_blank";
    link.textContent = event.detail.name || "";
    const grade = document.createElement("span");
    grade.className = "text-gray-400 ml-1";
    grade.textContent = event.detail.grade || "";
    const html = link.outerHTML + grade.outerHTML;
     
    this.openPopup(coordinates, html)
  }

  gotoarea(event) {
    this.flyToBounds([[event.detail.south_west_lon, event.detail.south_west_lat], [event.detail.north_east_lon, event.detail.north_east_lat]])
  }
}