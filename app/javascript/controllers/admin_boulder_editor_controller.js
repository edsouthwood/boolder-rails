import { Controller } from '@hotwired/stimulus'
import { insertionIndex, crossingEdges } from 'polygon_geometry'

// States: 'idle' | 'drawing' | 'selected'

export default class extends Controller {
  static targets = [
    'mapContainer', 'drawBtn', 'drawingActions', 'selectedActions',
    'status', 'count', 'countSuffix', 'boulderList', 'basemapBtn', 'attribution',
    'toggleProblemsBtn', 'lidarBtn', 'lidarOpacity',
    'suggestBtn', 'suggestStatus', 'useLidarBtn', 'addAllBtn',
    'nameInput', 'nameOptions', 'nameOptionsBox', 'unplacedSection', 'unplacedList',
    'hideBtn', 'hiddenNote', 'removePointBtn',
    'imageInput', 'imageChooseBtn', 'imageControls', 'imageOpacity', 'imageAdjustBtn',
  ]
  static values = {
    geojsonUrl: String,
    createUrl: String,
    updateUrlTemplate: String,
    deleteUrlTemplate: String,
    visibilityUrlTemplate: String,
    bounds: Object,
    maptilerKey: String,
    azureKey: String,
    mapboxKey: String,
    // Names from a problem list with no outline yet: [{ id, name, problems }]
    unplaced: { type: Array, default: [] },
    focusId: Number, // ?boulder=ID: zoom to and select it
    placeId: Number, // ?place=ID: start drawing the outline for that listed name
  }

  connect() {
    if (typeof maplibregl === 'undefined') {
      window.addEventListener('maplibre-ready', () => this.connect(), { once: true })
      return
    }

    this.state = 'idle'
    this.drawCoords = []
    this.drawMarkers = []
    this.drawHistory = [] // markers in the order they were clicked, for Backspace
    this.vertexMarkers = []
    this.midpointMarkers = []
    this.pickedIndex = null // the corner picked for removal
    this.dirty = false // unsaved changes to the selected outline
    this.selectedBoulderId = null
    this.bouldersGeoJSON = { type: 'FeatureCollection', features: [] }
    this.problemFeatures = []
    this.problemsVisible = false
    this.suggestions = []
    this.originalRing = null
    this.unplaced = [...this.unplacedValue]
    this.placing = null // the listed name being drawn, if any

    const bounds = this.boundsValue
    const sw = bounds.south_west
    const ne = bounds.north_east

    this.map = new maplibregl.Map({
      container: this.mapContainerTarget,
      style: {
        version: 8,
        sources: {
          satellite: {
            type: 'raster',
            tiles: ['https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'],
            tileSize: 256,
            attribution: 'Tiles © Esri'
          }
        },
        layers: [{ id: 'satellite', type: 'raster', source: 'satellite' }]
      },
      bounds: [[sw.lng, sw.lat], [ne.lng, ne.lat]],
      fitBoundsOptions: { padding: this.fitPadding(60) },
    })

    this.map.addControl(new maplibregl.NavigationControl())
    this.map.addControl(new maplibregl.ScaleControl({ maxWidth: 100, unit: 'metric' }))

    this.map.on('load', () => {
      // Added before loadData so it sits between the satellite and the boulder layers
      this.addLidarLayer()
      this.loadData()
      const saved = localStorage.getItem('boulder-editor-basemap')
      if (saved && this.basemapSources[saved]) {
        this.map.getSource('satellite').setTiles(this.basemapSources[saved].tiles)
        this.highlightBasemapBtn(saved)
      } else {
        this.highlightBasemapBtn('esri')
      }
    })

    // Small edges' midpoint dots show or hide as the zoom changes
    this.map.on('zoomend', () => this.positionMidpoints())

    // Keyboard: Escape cancels drawing or un-picks a corner; Delete/Backspace removes the
    // last point drawn, or the picked corner. Not while typing (the Name box).
    this._onKeyDown = (e) => {
      if (e.target.closest?.('input, textarea, select, [contenteditable]')) return
      if (e.key === 'Escape') {
        if (this.state === 'drawing') this.cancelDrawing()
        else this.unpickVertex()
      } else if (e.key === 'Delete' || e.key === 'Backspace') {
        if (this.state === 'drawing') { e.preventDefault(); this.removeLastDrawnPoint() }
        else if (this.pickedIndex != null) { e.preventDefault(); this.removePickedPoint() }
      }
    }
    document.addEventListener('keydown', this._onKeyDown)
  }

  // ─── Data loading ───────────────────────────────────────────────────────────

  loadData() {
    // LiDAR suggestions (filled by suggestBoulders), drawn beneath the boulders
    this.map.addSource('suggestions', {
      type: 'geojson',
      data: { type: 'FeatureCollection', features: [] },
    })
    const suggestionColor = ['case', ['get', 'overlaps'], '#16a34a', '#f59e0b'] // green overlaps, amber new
    this.map.addLayer({
      id: 'suggestions-fill',
      type: 'fill',
      source: 'suggestions',
      paint: { 'fill-color': suggestionColor, 'fill-opacity': 0.25 },
    })
    this.map.addLayer({
      id: 'suggestions-line',
      type: 'line',
      source: 'suggestions',
      paint: { 'line-color': suggestionColor, 'line-width': 2, 'line-dasharray': [2, 1.5] },
    })

    // Boulder polygons source (mutable — we update it in-place)
    this.map.addSource('boulders', {
      type: 'geojson',
      data: this.bouldersGeoJSON,
      promoteId: 'boulderId',
    })

    // Boulders fill
    this.map.addLayer({
      id: 'boulders-fill',
      type: 'fill',
      source: 'boulders',
      paint: {
        'fill-color': [
          'case',
          ['boolean', ['feature-state', 'selected'], false],
          '#3b82f6', // blue when selected
          ['boolean', ['get', 'hidden'], false],
          '#f59e0b', // amber when hidden from the public site
          '#888888'  // grey otherwise
        ],
        'fill-opacity': ['case', ['boolean', ['get', 'hidden'], false], 0.2, 0.5],
      },
      filter: ['==', ['geometry-type'], 'Polygon'],
    })

    // Boulders outline
    this.map.addLayer({
      id: 'boulders-outline',
      type: 'line',
      source: 'boulders',
      paint: {
        'line-color': [
          'case',
          ['boolean', ['feature-state', 'selected'], false],
          '#1d4ed8',
          ['boolean', ['get', 'hidden'], false],
          '#b45309',
          '#444444'
        ],
        'line-width': 2,
      },
      filter: ['==', ['geometry-type'], 'Polygon'],
    })

    // Draw preview source (LineString drawn mid-trace)
    this.map.addSource('draw-preview', {
      type: 'geojson',
      data: { type: 'Feature', geometry: { type: 'LineString', coordinates: [] } }
    })

    this.map.addLayer({
      id: 'draw-preview-line',
      type: 'line',
      source: 'draw-preview',
      paint: { 'line-color': '#f59e0b', 'line-width': 2, 'line-dasharray': [2, 2] },
    })

    // Edges of the outline being drawn or edited that cross another of its edges (a bow-tie)
    this.map.addSource('crossings', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } })
    this.map.addLayer({
      id: 'crossings',
      type: 'line',
      source: 'crossings',
      paint: { 'line-color': '#dc2626', 'line-width': 5 },
    })

    // Problem markers (toggled on/off; starts hidden)
    this.map.addSource('problems', {
      type: 'geojson',
      data: { type: 'FeatureCollection', features: [] }
    })
    this.map.addLayer({
      id: 'problems',
      type: 'circle',
      source: 'problems',
      layout: { visibility: 'none' },
      paint: {
        'circle-radius': 5,
        'circle-color': ['coalesce', ['get', 'marker-color'], '#cccccc'],
        'circle-stroke-width': 1.5,
        'circle-stroke-color': '#ffffff',
      }
    })

    const problemPopup = new maplibregl.Popup({ offset: 8, closeButton: false, closeOnClick: false })
    this.map.on('mousemove', 'problems', (e) => {
      this.map.getCanvas().style.cursor = 'default'
      problemPopup.setLngLat(e.lngLat).setText(e.features[0].properties.name).addTo(this.map)
    })
    this.map.on('mouseleave', 'problems', () => {
      this.map.getCanvas().style.cursor = ''
      problemPopup.remove()
    })

    // Click on boulders-fill to select
    this.map.on('click', 'boulders-fill', (e) => {
      if (this.state !== 'idle' && this.state !== 'selected') return
      const id = e.features[0]?.properties?.boulderId
      if (id == null) return
      if (this.selectedBoulderId == id) {
        this.deselect()
      } else {
        this.selectBoulder(id)
      }
    })

    // Click on empty map to deselect
    this.map.on('click', (e) => {
      if (this.state !== 'idle') return
      const features = this.map.queryRenderedFeatures(e.point, { layers: ['boulders-fill'] })
      if (features.length === 0) this.deselect()
    })

    // Click on a suggestion (outside any boulder) to offer adding or replacing
    this.map.on('click', 'suggestions-fill', (e) => {
      if (this.state === 'drawing') return
      if (this.map.queryRenderedFeatures(e.point, { layers: ['boulders-fill'] }).length) return
      this.showSuggestionPopup(e.features[0].properties.index, e.lngLat)
    })
    this.map.on('mouseenter', 'suggestions-fill', () => {
      if (this.state !== 'drawing') this.map.getCanvas().style.cursor = 'pointer'
    })
    this.map.on('mouseleave', 'suggestions-fill', () => {
      if (this.state !== 'drawing') this.map.getCanvas().style.cursor = ''
    })

    // Change cursor over boulders
    this.map.on('mouseenter', 'boulders-fill', () => {
      if (this.state === 'idle') this.map.getCanvas().style.cursor = 'pointer'
    })
    this.map.on('mouseleave', 'boulders-fill', () => {
      if (this.state === 'idle') this.map.getCanvas().style.cursor = ''
    })

    // Fetch existing boulders
    fetch(this.geojsonUrlValue)
      .then(r => r.json())
      .then(data => {
        this.bouldersGeoJSON.features = data.features.filter(f => f.geometry.type === 'Polygon')
        this.problemFeatures = data.features.filter(f => f.geometry.type === 'Point')
        this.map.getSource('boulders').setData(this.bouldersGeoJSON)
        this.map.getSource('problems').setData({ type: 'FeatureCollection', features: this.problemFeatures })
        this.renderBoulderList()
        this.renderUnplaced()
        this.updateCount(this.bouldersGeoJSON.features.length)
        this.fitToPinsIfNothingDrawn()
        if (this.hasFocusIdValue) this.focusBoulder(this.focusIdValue)
        if (this.hasPlaceIdValue) this.startPlacing(this.placeIdValue)
      })
  }

  // ─── Drawing ────────────────────────────────────────────────────────────────

  startDrawing() {
    this.deselect()
    if (this.overlayHandles) this.setOverlayAdjusting(false) // handles would catch the clicks
    this.state = 'drawing'
    this.drawCoords = []
    this.drawHistory = []
    this.map.getCanvas().style.cursor = 'crosshair'

    this.drawingActionsTarget.classList.remove('hidden')
    this.drawBtnTarget.classList.add('hidden')
    this.setStatus('Click to add vertices…')

    this._onMapClick = (e) => this.addVertex(e)
    this._onMapDblClick = (e) => this.finishPolygon(e)

    this.map.on('click', this._onMapClick)
    this.map.on('dblclick', this._onMapDblClick)
    // Prevent map from zooming on double-click during drawing
    this.map.doubleClickZoom.disable()
  }

  addVertex(e) {
    if (this.state !== 'drawing') return
    // A click on (or within a few pixels of) a corner already placed adds nothing: that's
    // the second click of a double-click, or a slip. Recorded as null so Backspace skips it.
    if (this.drawMarkers.some(m => this.map.project(m.getLngLat()).dist(e.point) < 5)) {
      this.drawHistory.push(null)
      return
    }
    const coord = [e.lngLat.lng, e.lngLat.lat]
    // Corners clicked in any order: each goes where it makes no crossing (usually the end)
    const index = insertionIndex(this.drawCoords.map(c => this.flat(c)), this.flat(coord))
    this.drawCoords.splice(index, 0, coord)

    // Add a small yellow dot marker at this vertex
    const el = document.createElement('div')
    el.className = 'w-2 h-2 rounded-full bg-amber-400 border border-white'
    const marker = new maplibregl.Marker({ element: el }).setLngLat(coord).addTo(this.map)
    this.drawMarkers.splice(index, 0, marker)
    this.drawHistory.push(marker)
    this.updateDrawPreview()
  }

  // Takes back the point clicked last, wherever it went in the outline
  removeLastDrawnPoint() {
    let marker = this.drawHistory.pop()
    while (marker === null) marker = this.drawHistory.pop()
    if (!marker) return
    const index = this.drawMarkers.indexOf(marker)
    this.drawCoords.splice(index, 1)
    this.drawMarkers.splice(index, 1)
    marker.remove()
    this.updateDrawPreview()
  }

  // The outline so far, closed once it has 3 corners so you can see the shape it will make
  updateDrawPreview() {
    const coords = this.drawCoords.length >= 3 ? [...this.drawCoords, this.drawCoords[0]] : this.drawCoords
    this.map.getSource('draw-preview').setData({ type: 'Feature', geometry: { type: 'LineString', coordinates: coords } })
    this.showCrossings(this.drawCoords)
  }

  // lng/lat with lng scaled by cos(latitude), so distances are fair for choosing where a corner goes
  flat([lng, lat]) {
    return [lng * Math.cos(lat * Math.PI / 180), lat]
  }

  // Edges of this outline that cross another of its edges, drawn thick red, with a warning
  // when one first appears. The server refuses to save an edited outline like that.
  showCrossings(coords) {
    const edges = coords.length ? crossingEdges(coords.map(c => this.flat(c))) : []
    this.map.getSource('crossings')?.setData({
      type: 'FeatureCollection',
      features: edges.map(i => ({
        type: 'Feature', properties: {},
        geometry: { type: 'LineString', coordinates: [coords[i], coords[(i + 1) % coords.length]] },
      })),
    })
    if (edges.length && !this.crossingCount) this.setStatus('Edges cross (shown in red): move or remove a corner to untangle them')
    this.crossingCount = edges.length
  }

  finishPolygon(e) {
    e.preventDefault?.()
    if (this.state !== 'drawing') return

    // dblclick fires after 2 click events: the 2nd landed on the corner the 1st placed, so
    // added nothing (see addVertex). If the mouse moved between them it did add one: drop it.
    const second = this.drawHistory[this.drawHistory.length - 1]
    const coordinates = second ? this.drawCoords.filter((_, i) => i !== this.drawMarkers.indexOf(second)) : this.drawCoords

    if (coordinates.length < 3) {
      this.showToast('Need at least 3 points', true)
      return
    }
    const placing = this.placing
    this.exitDrawingMode()
    this.createBoulder(coordinates, placing)
  }

  // Saves a new boulder outline, or the outline of a listed name (placing); resolves to its
  // id, or null if it wasn't saved
  createBoulder(coordinates, placing = null) {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    return fetch(this.createUrlValue, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': csrfToken,
      },
      body: JSON.stringify({ coordinates, boulder_id: placing?.id }),
    })
      .then(r => r.json())
      .then(data => {
        if (data.error) { this.showToast(data.error, true); return null }

        // Add new feature to local GeoJSON
        const closed = [...coordinates, coordinates[0]]
        const feature = {
          type: 'Feature',
          id: data.id,
          properties: { boulderId: data.id, name: data.name || null },
          geometry: { type: 'Polygon', coordinates: [closed] }
        }
        this.bouldersGeoJSON.features.push(feature)
        this.map.getSource('boulders').setData(this.bouldersGeoJSON)

        const newCount = this.bouldersGeoJSON.features.length
        this.updateCount(newCount)
        this.renderBoulderList()
        if (placing) {
          this.unplaced = this.unplaced.filter(u => u.id !== placing.id)
          this.renderUnplaced()
        }
        this.showToast(`${this.labelFor(data.id)} saved`)
        return data.id
      })
      .catch(() => { this.showToast('Network error — not saved', true); return null })
  }

  cancelDrawing() {
    if (this.state !== 'drawing') return
    this.exitDrawingMode()
    this.setStatus('Cancelled')
    setTimeout(() => this.setStatus('Click a polygon to select'), 1500)
  }

  exitDrawingMode() {
    this.state = 'idle'
    this.placing = null
    this.drawCoords = []
    this.map.getCanvas().style.cursor = ''
    this.map.off('click', this._onMapClick)
    this.map.off('dblclick', this._onMapDblClick)
    this.map.doubleClickZoom.enable()

    // Remove draw vertex dot markers
    ;(this.drawMarkers || []).forEach(m => m.remove())
    this.drawMarkers = []

    this.drawHistory = []

    // Clear preview line
    this.map.getSource('draw-preview').setData({
      type: 'Feature', geometry: { type: 'LineString', coordinates: [] }
    })
    this.showCrossings([])

    this.drawingActionsTarget.classList.add('hidden')
    this.drawBtnTarget.classList.remove('hidden')
  }

  // ─── Selection & editing ─────────────────────────────────────────────────────

  selectBoulder(boulderId) {
    // Deselect previous, undoing any unsaved changes to it
    if (this.selectedBoulderId != null) this.deselect()

    this.selectedBoulderId = boulderId
    this.state = 'selected'
    this.map.setFeatureState({ source: 'boulders', id: boulderId }, { selected: true })

    this.selectedActionsTarget.classList.remove('hidden')
    this.setStatus(`${this.labelFor(boulderId)} selected`)
    this.fillNameField(boulderId)
    this.renderHiddenState(boulderId)

    // Find the feature and place draggable vertex markers
    const feature = this.bouldersGeoJSON.features.find(
      f => f.properties.boulderId == boulderId
    )
    if (!feature) return

    const ring = feature.geometry.coordinates[0]
    // Kept so deselecting without saving puts the outline back
    this.originalRing = ring.map(c => [...c])
    // Skip last coord if it closes the ring (equals first)
    const coords = ring[0][0] === ring[ring.length - 1][0] && ring[0][1] === ring[ring.length - 1][1]
      ? ring.slice(0, -1)
      : ring

    this.placeVertexMarkers(coords)
    this.showCrossings(coords) // an older outline may already cross itself: show where
    this.useLidarBtnTarget.classList.toggle('hidden', !this.suggestionFor(boulderId))
  }

  // Corner dots (drag to move; click to pick for removal; Alt-click removes) and, halfway
  // along each edge, fainter dots that add a corner there (drag one, or click it)
  placeVertexMarkers(coords) {
    this.clearVertexMarkers()
    coords.forEach(([lng, lat]) => {
      const el = document.createElement('div')
      el.className = 'w-3 h-3 rounded-full bg-blue-500 border-2 border-white cursor-move shadow'
      el.title = 'Drag to move. Click to pick it, then Remove point (or Alt-click to remove it)'

      const marker = new maplibregl.Marker({ element: el, draggable: true })
        .setLngLat([lng, lat])
        .addTo(this.map)

      // Live-update polygon outline while dragging
      marker.on('dragstart', () => { this.unpickVertex() })
      marker.on('drag', () => { this.refreshSelectedPolygon(); this.positionMidpoints() })
      marker.on('dragend', () => { this.justDragged = true; setTimeout(() => { this.justDragged = false }, 0); this.markUnsaved() })
      // Stop the click reaching the map, which would deselect the boulder
      el.addEventListener('click', (e) => {
        e.stopPropagation()
        if (this.justDragged) return
        const index = this.vertexMarkers.indexOf(marker)
        if (e.altKey) this.removePoint(index)
        else if (this.pickedIndex === index) this.unpickVertex()
        else this.pickVertex(index)
      })

      this.vertexMarkers.push(marker)
    })
    this.placeMidpoints()
  }

  vertexCoords() {
    return this.vertexMarkers.map(m => {
      const ll = m.getLngLat()
      return [ll.lng, ll.lat]
    })
  }

  // One faint dot per edge, between corner i and the next
  placeMidpoints() {
    this.midpointMarkers.forEach(m => m.remove())
    this.midpointMarkers = this.vertexMarkers.map((_, i) => {
      const el = document.createElement('div')
      el.className = 'w-2.5 h-2.5 rounded-full bg-white/70 border border-blue-500 cursor-copy'
      el.title = 'Drag (or click) to add a corner here'
      const marker = new maplibregl.Marker({ element: el, draggable: true })
        .setLngLat(this.midpointOf(i))
        .addTo(this.map)

      // Dragging it previews the new corner; it becomes one when let go
      marker.on('dragstart', () => { this.unpickVertex(); this.draggingMidpoint = { index: i + 1, marker } })
      marker.on('drag', () => this.refreshSelectedPolygon())
      marker.on('dragend', () => {
        this.draggingMidpoint = null
        this.justDragged = true
        setTimeout(() => { this.justDragged = false }, 0)
        const ll = marker.getLngLat()
        this.insertPoint(i + 1, [ll.lng, ll.lat])
      })
      el.addEventListener('click', (e) => {
        e.stopPropagation()
        if (this.justDragged) return
        this.insertPoint(i + 1, this.midpointOf(i))
      })
      return marker
    })
    this.positionMidpoints()
  }

  midpointOf(i) {
    const a = this.vertexMarkers[i].getLngLat()
    const b = this.vertexMarkers[(i + 1) % this.vertexMarkers.length].getLngLat()
    return [(a.lng + b.lng) / 2, (a.lat + b.lat) / 2]
  }

  // Keeps the midpoints halfway along their edges, hiding them on edges too short on screen
  // to grab without catching a corner
  positionMidpoints() {
    this.midpointMarkers.forEach((marker, i) => {
      if (this.draggingMidpoint?.marker === marker) return
      const a = this.map.project(this.vertexMarkers[i].getLngLat())
      const b = this.map.project(this.vertexMarkers[(i + 1) % this.vertexMarkers.length].getLngLat())
      marker.setLngLat(this.midpointOf(i))
      marker.getElement().style.visibility = Math.hypot(a.x - b.x, a.y - b.y) < 24 ? 'hidden' : ''
    })
  }

  insertPoint(index, lngLat) {
    const coords = this.vertexCoords()
    coords.splice(index, 0, lngLat)
    this.placeVertexMarkers(coords)
    this.refreshSelectedPolygon()
    this.markUnsaved()
  }

  removePoint(index) {
    if (index < 0 || index >= this.vertexMarkers.length) return
    if (this.vertexMarkers.length <= 3) {
      this.showToast('An outline needs at least 3 points', true)
      return
    }
    const coords = this.vertexCoords()
    coords.splice(index, 1)
    this.placeVertexMarkers(coords)
    this.refreshSelectedPolygon()
    this.markUnsaved()
  }

  removePickedPoint() {
    if (this.pickedIndex != null) this.removePoint(this.pickedIndex)
  }

  pickVertex(index) {
    this.unpickVertex()
    this.pickedIndex = index
    // classList, not className: maplibre's own marker classes are on the element too
    this.vertexMarkers[index]?.getElement().classList.add('ring-2', 'ring-red-500', 'bg-red-500')
    this.vertexMarkers[index]?.getElement().classList.remove('bg-blue-500')
    if (this.hasRemovePointBtnTarget) this.removePointBtnTarget.disabled = false
    this.setStatus('Point picked: Remove point (or Delete) removes it, Esc keeps it')
  }

  unpickVertex() {
    const el = this.pickedIndex != null && this.vertexMarkers[this.pickedIndex]?.getElement()
    if (el) {
      el.classList.remove('ring-2', 'ring-red-500', 'bg-red-500')
      el.classList.add('bg-blue-500')
    }
    const wasPicked = this.pickedIndex != null
    this.pickedIndex = null
    if (this.hasRemovePointBtnTarget) this.removePointBtnTarget.disabled = true
    if (wasPicked) this.showSelectedStatus()
  }

  markUnsaved() {
    this.dirty = true
    this.showSelectedStatus()
  }

  showSelectedStatus() {
    if (this.selectedBoulderId == null) return
    if (this.crossingCount) return this.setStatus('Edges cross (shown in red): move or remove a corner to untangle them')
    this.setStatus(this.dirty
      ? `${this.labelFor(this.selectedBoulderId)}: unsaved changes. Save changes to keep them`
      : `${this.labelFor(this.selectedBoulderId)} selected`)
  }

  refreshSelectedPolygon() {
    const feature = this.bouldersGeoJSON.features.find(
      f => f.properties.boulderId == this.selectedBoulderId
    )
    if (!feature) return

    const coords = this.vertexCoords()
    if (this.draggingMidpoint) {
      const ll = this.draggingMidpoint.marker.getLngLat()
      coords.splice(this.draggingMidpoint.index, 0, [ll.lng, ll.lat])
    }
    const closed = [...coords, coords[0]]
    feature.geometry.coordinates = [closed]
    this.map.getSource('boulders').setData(this.bouldersGeoJSON)
    this.showCrossings(coords)
  }

  deselect() {
    if (this.selectedBoulderId != null) {
      // Undo unsaved vertex moves (or a LiDAR outline that wasn't saved)
      const feature = this.bouldersGeoJSON.features.find(f => f.properties.boulderId == this.selectedBoulderId)
      if (feature && this.originalRing) {
        feature.geometry.coordinates = [this.originalRing]
        this.map.getSource('boulders').setData(this.bouldersGeoJSON)
      }
      this.map.setFeatureState({ source: 'boulders', id: this.selectedBoulderId }, { selected: false })
      this.selectedBoulderId = null
    }
    this.originalRing = null
    this.dirty = false
    this.showCrossings([])
    this.crossingMarker?.remove()
    this.suggestionPopup?.remove()
    this.state = 'idle'
    this.clearVertexMarkers()
    this.selectedActionsTarget.classList.add('hidden')
    this.setStatus('Click a polygon to select')
  }

  saveSelected() {
    if (!this.selectedBoulderId || this.vertexMarkers.length < 3) return

    const coordinates = this.vertexCoords()

    const url = this.updateUrlTemplateValue.replace('BOULDER_ID', this.selectedBoulderId)
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    fetch(url, {
      method: 'PATCH',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': csrfToken,
      },
      body: JSON.stringify({ coordinates }),
    })
      .then(r => r.json())
      .then(data => {
        if (data.error) {
          this.showToast(data.error, true)
          if (data.crossing) this.showCrossing(data.crossing)
          return
        }
        this.crossingMarker?.remove()
        this.originalRing = [...coordinates, coordinates[0]]
        this.dirty = false
        this.showSelectedStatus()
        this.showToast(`Boulder #${this.selectedBoulderId} saved`)
      })
      .catch(() => this.showToast('Network error — not saved', true))
  }

  // A red ring where the server found the outline crossing itself, panned into view
  showCrossing([lng, lat]) {
    this.crossingMarker?.remove()
    const el = document.createElement('div')
    el.className = 'w-6 h-6 rounded-full border-4 border-red-500 pointer-events-none'
    this.crossingMarker = new maplibregl.Marker({ element: el }).setLngLat([lng, lat]).addTo(this.map)
    this.map.easeTo({ center: [lng, lat] })
    this.setStatus('The outline crosses itself at the red ring: move or remove a point there')
  }

  deleteSelected() {
    if (!this.selectedBoulderId) return
    const named = this.bouldersGeoJSON.features.find(f => f.properties.boulderId == this.selectedBoulderId)?.properties.name
    if (!confirm(named
      ? `Delete ${named} (#${this.selectedBoulderId})? Its problems will no longer be on a boulder.`
      : `Delete boulder #${this.selectedBoulderId}?`)) return

    const boulderId = this.selectedBoulderId
    const url = this.deleteUrlTemplateValue.replace('BOULDER_ID', boulderId)
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    fetch(url, {
      method: 'DELETE',
      headers: { 'Accept': 'application/json', 'X-CSRF-Token': csrfToken },
    })
      .then(r => r.json())
      .then(data => {
        if (data.error) { this.showToast(data.error, true); return }

        this.bouldersGeoJSON.features = this.bouldersGeoJSON.features.filter(
          f => f.properties.boulderId != boulderId
        )
        this.map.getSource('boulders').setData(this.bouldersGeoJSON)

        this.updateCount(this.bouldersGeoJSON.features.length)
        this.renderBoulderList()
        this.deselect()
        this.showToast(`Boulder #${boulderId} deleted`)
      })
      .catch(() => this.showToast('Network error — not deleted', true))
  }

  // Hide the selected boulder (outline and problems) from the public site, or bring it back
  toggleHidden() {
    if (!this.selectedBoulderId) return
    const boulderId = this.selectedBoulderId
    const feature = this.bouldersGeoJSON.features.find(f => f.properties.boulderId == boulderId)
    if (!feature) return
    const hidden = !feature.properties.hidden
    const url = this.visibilityUrlTemplateValue.replace('BOULDER_ID', boulderId)
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    fetch(url, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json', 'Accept': 'application/json', 'X-CSRF-Token': csrfToken },
      body: JSON.stringify({ hidden }),
    })
      .then(r => r.json())
      .then(data => {
        if (data.error) { this.showToast(data.error, true); return }
        feature.properties.hidden = data.hidden
        this.map.getSource('boulders').setData(this.bouldersGeoJSON)
        this.renderBoulderList()
        if (this.selectedBoulderId == boulderId) this.renderHiddenState(boulderId)
        this.showToast(data.hidden
          ? `${this.labelFor(boulderId)} hidden: it and its problems are off the public site`
          : `${this.labelFor(boulderId)} is back on the public site`)
      })
      .catch(() => this.showToast('Network error — not changed', true))
  }

  renderHiddenState(boulderId) {
    const hidden = !!this.bouldersGeoJSON.features.find(f => f.properties.boulderId == boulderId)?.properties.hidden
    if (this.hasHideBtnTarget) this.hideBtnTarget.textContent = hidden ? 'Show on the public site again' : 'Hide boulder from the public site'
    if (this.hasHiddenNoteTarget) this.hiddenNoteTarget.classList.toggle('hidden', !hidden)
  }

  // ─── Sidebar ─────────────────────────────────────────────────────────────────

  // Named boulders first (alphabetically), then unnamed ones by id
  renderBoulderList() {
    const features = [...this.bouldersGeoJSON.features].sort((a, b) => {
      const [na, nb] = [a.properties.name, b.properties.name]
      if (na && nb) return na.localeCompare(nb)
      if (na || nb) return na ? -1 : 1
      return a.properties.boulderId - b.properties.boulderId
    })
    this.boulderListTarget.replaceChildren()
    if (features.length === 0) {
      this.boulderListTarget.append(this.element_('p', 'italic text-gray-400 py-2', 'No boulders yet.'))
      return
    }
    features.forEach(f => {
      const row = this.element_('div', 'py-1 cursor-pointer hover:text-granite-dark', this.labelFor(f.properties.boulderId))
      if (f.properties.name) row.classList.add('text-gray-800')
      if (f.properties.hidden) {
        row.classList.add('text-gray-400')
        row.append(this.element_('span', 'ml-1 text-xs text-amber-700', 'hidden'))
      }
      row.dataset.boulderId = f.properties.boulderId
      row.dataset.action = 'click->admin-boulder-editor#sidebarClick'
      this.boulderListTarget.append(row)
    })
  }

  sidebarClick(e) {
    if (this.state !== 'idle' && this.state !== 'selected') return
    this.focusBoulder(parseInt(e.currentTarget.dataset.boulderId, 10))
  }

  // Selects a boulder and flies to it
  focusBoulder(id) {
    const feature = this.bouldersGeoJSON.features.find(f => f.properties.boulderId == id)
    if (!feature) return
    this.deselect()
    this.selectBoulder(id)
    const coords = feature.geometry.coordinates[0]
    const lngs = coords.map(c => c[0])
    const lats = coords.map(c => c[1])
    this.map.fitBounds(
      [[Math.min(...lngs), Math.min(...lats)], [Math.max(...lngs), Math.max(...lats)]],
      { padding: this.fitPadding(80), maxZoom: 20 }
    )
  }

  labelFor(boulderId) {
    const name = this.bouldersGeoJSON.features.find(f => f.properties.boulderId == boulderId)?.properties.name
    return name ? `${name} (#${boulderId})` : `Boulder #${boulderId}`
  }

  element_(tag, className, text) {
    const el = document.createElement(tag)
    if (className) el.className = className
    if (text != null) el.textContent = text
    return el
  }

  // ─── Names ──────────────────────────────────────────────────────────────────

  fillNameField(boulderId) {
    const feature = this.bouldersGeoJSON.features.find(f => f.properties.boulderId == boulderId)
    this.nameInputTarget.value = feature?.properties.name || ''
    this.renderNameOptions()
  }

  // The listed names (from a problem list, not on the map yet) shown under the Name box,
  // narrowed by what's typed. A visible list rather than a <datalist>, which some browsers
  // (Safari, iPad) show badly or not at all.
  renderNameOptions() {
    const query = this.nameInputTarget.value.trim().toLowerCase()
    const current = this.bouldersGeoJSON?.features.find(f => f.properties.boulderId == this.selectedBoulderId)?.properties.name
    const typing = query && query !== (current || '').toLowerCase()
    const matches = this.unplaced.filter(u => !typing || u.name.toLowerCase().includes(query))

    this.nameOptionsBoxTarget.classList.toggle('hidden', this.unplaced.length === 0)
    if (!matches.length) {
      this.nameOptionsTarget.replaceChildren(this.element_('p', 'px-2 py-1.5 text-xs text-gray-400 italic', 'No listed name matches. Set saves it as a new name.'))
      return
    }
    this.nameOptionsTarget.replaceChildren(...matches.map(u => {
      const row = this.element_('button', 'flex w-full items-center gap-2 px-2 py-1.5 text-left text-xs text-gray-800 hover:bg-amber-50')
      row.type = 'button'
      row.title = `Name this outline ${u.name}`
      row.append(this.element_('span', 'flex-1 min-w-0 truncate font-medium', u.name))
      row.append(this.element_('span', 'text-gray-400 shrink-0', `${u.problems} problem${u.problems === 1 ? '' : 's'}`))
      row.addEventListener('click', () => {
        this.nameInputTarget.value = u.name
        this.saveName()
      })
      return row
    }))
  }

  // Names the selected outline. A listed name (not on the map yet) merges into it, bringing
  // that boulder's problems with it.
  // Renaming an outline that already has a listed name's problems to another listed name
  // asks first (the server replies 409 with needs_choice): swap the names, putting the old
  // one back on the list with its problems, or merge both lots of problems onto this outline.
  saveName(event, merge = null) {
    event?.preventDefault()
    if (!this.selectedBoulderId) return
    const boulderId = this.selectedBoulderId
    const url = this.updateUrlTemplateValue.replace('BOULDER_ID', boulderId)
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    const plural = n => `${n} problem${n === 1 ? '' : 's'}`

    fetch(url, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json', 'Accept': 'application/json', 'X-CSRF-Token': csrfToken },
      body: JSON.stringify({ name: this.nameInputTarget.value, ...(merge ? { merge } : {}) }),
    })
      .then(r => r.json())
      .then(data => {
        if (data.needs_choice) {
          if (window.confirm(`This outline is "${data.current}", with ${plural(data.current_problems)}.\n\n` +
              `OK: rename it "${data.target}" (with its ${plural(data.target_problems)}) and put "${data.current}" back on the list of names to draw.\n\n` +
              `Cancel: choose something else.`)) return this.saveName(null, 'swap')
          if (window.confirm(`Or keep both: give this outline the problems of "${data.current}" and "${data.target}" ` +
              `(${plural(data.current_problems + data.target_problems)}), named "${data.target}"?`)) return this.saveName(null, 'merge')
          this.fillNameField(boulderId)
          return
        }
        if (data.error) { this.showToast(data.error, true); return }
        if (data.relisted) {
          this.unplaced = [...this.unplaced, data.relisted].sort((a, b) => a.name.localeCompare(b.name))
          this.renderUnplaced()
        }
        const feature = this.bouldersGeoJSON.features.find(f => f.properties.boulderId == boulderId)
        if (feature) feature.properties.name = data.name || null
        const absorbed = this.unplaced.find(u => u.id === data.absorbed_id)
        if (absorbed) {
          this.unplaced = this.unplaced.filter(u => u.id !== absorbed.id)
          this.renderUnplaced()
        }
        this.renderBoulderList()
        if (this.selectedBoulderId == boulderId) {
          this.fillNameField(boulderId)
          this.setStatus(`${this.labelFor(boulderId)} selected`)
        }
        this.showToast(absorbed
          ? `Named ${data.name}: ${absorbed.problems} problem${absorbed.problems === 1 ? '' : 's'} now on #${boulderId}` +
            (data.relisted ? `. ${data.relisted.name} is back on the list to draw` : '')
          : (data.name ? `Named ${data.name}` : `Boulder #${boulderId} has no name`))
      })
      .catch(() => this.showToast('Network error — not saved', true))
  }

  renderUnplaced() {
    this.unplacedSectionTarget.classList.toggle('hidden', this.unplaced.length === 0)
    this.renderPins()
    this.unplacedListTarget.replaceChildren(...this.unplaced.map(u => {
      const row = this.element_('button', 'block w-full text-left py-0.5 text-gray-700 hover:text-granite-dark', u.name)
      row.type = 'button'
      row.append(this.element_('span', 'text-gray-400', ` · ${u.problems}`))
      if (u.lat != null) {
        row.append(this.element_('span', 'text-sky-600', ' · pin'))
        row.title = 'Has an approximate location from a map-points import: click to go there and draw it'
      }
      row.dataset.boulderId = u.id
      row.dataset.action = 'click->admin-boulder-editor#placeClick'
      return row
    }))
  }

  placeClick(e) {
    this.startPlacing(parseInt(e.currentTarget.dataset.boulderId, 10))
  }

  // Pins for listed names that have an approximate location (from a map-points import) but
  // no outline yet. Plain markers: not draggable, and their element's classes are set once,
  // before maplibre adds its own (replacing className later drops maplibregl-marker).
  renderPins() {
    (this.pinMarkers || []).forEach(marker => marker.remove())
    this.pinMarkers = this.unplaced.filter(u => u.lat != null).map(u => {
      const el = document.createElement('button')
      el.type = 'button'
      el.className = 'flex items-center gap-1 text-[11px] leading-none text-white whitespace-nowrap'
      el.title = `${u.name}: approximate position. Click to draw its outline here.`
      const dot = this.element_('span', 'block w-2.5 h-2.5 rounded-full bg-sky-500 ring-2 ring-white', '')
      const label = this.element_('span', 'px-1 py-0.5 rounded bg-black/60', u.name)
      el.append(dot, label)
      el.addEventListener('click', (e) => { e.stopPropagation(); if (this.state !== 'drawing') this.startPlacing(u.id) })
      return new maplibregl.Marker({ element: el, anchor: 'left', offset: [-5, 0] }).setLngLat([u.lon, u.lat]).addTo(this.map)
    })
  }

  // With no outlines yet, the area's view comes from a few located problems at most: show
  // every pin (and those problems) instead
  fitToPinsIfNothingDrawn() {
    const pins = this.unplaced.filter(u => u.lat != null).map(u => [u.lon, u.lat])
    if (this.bouldersGeoJSON.features.length || pins.length < 2) return
    const points = [...pins, ...this.problemFeatures.map(f => f.geometry.coordinates)]
    const lngs = points.map(p => p[0]), lats = points.map(p => p[1])
    this.map.fitBounds([[Math.min(...lngs), Math.min(...lats)], [Math.max(...lngs), Math.max(...lats)]],
      { padding: this.fitPadding(60), maxZoom: 18, duration: 0 })
  }

  // The listed name whose pin sits on (or within a few metres of) a LiDAR suggestion, nearest first
  pinnedNameFor(suggestion) {
    const ring = suggestion.coordinates
    const lngs = ring.map(c => c[0]), lats = ring.map(c => c[1])
    const centre = [(Math.min(...lngs) + Math.max(...lngs)) / 2, (Math.min(...lats) + Math.max(...lats)) / 2]
    const metres = (a, b) => {
      const dx = (a[0] - b[0]) * 111320 * Math.cos(a[1] * Math.PI / 180)
      const dy = (a[1] - b[1]) * 110540
      return Math.hypot(dx, dy)
    }
    const radius = Math.max(...ring.map(c => metres(c, centre)))
    const best = this.unplaced.filter(u => u.lat != null)
      .map(u => ({ u, d: metres([u.lon, u.lat], centre) }))
      .filter(({ d }) => d <= radius + 8)
      .sort((a, b) => a.d - b.d)[0]
    return best?.u
  }

  // Draw mode for a listed name: the finished outline is saved onto that boulder
  startPlacing(id) {
    const listed = this.unplaced.find(u => u.id === id)
    if (!listed) return
    if (listed.lat != null) this.map.easeTo({ center: [listed.lon, listed.lat], zoom: Math.min(Math.max(this.map.getZoom(), 17.5), 18) })
    if (this.state === 'drawing') this.exitDrawingMode()
    this.startDrawing()
    this.placing = listed
    this.setStatus(`Drawing ${listed.name}: click to add vertices…`)
  }

  // ─── Problem marker toggle ────────────────────────────────────────────────────

  toggleProblems() {
    this.problemsVisible = !this.problemsVisible
    if (this.problemsVisible) {
      this.showProblemMarkers()
    } else {
      this.hideProblemMarkers()
    }
    this.toggleProblemsBtnTarget.textContent = this.problemsVisible ? 'Hide problems' : 'Show problems'
    this.toggleProblemsBtnTarget.classList.toggle('bg-indigo-600', this.problemsVisible)
    this.toggleProblemsBtnTarget.classList.toggle('text-white', this.problemsVisible)
    this.toggleProblemsBtnTarget.classList.toggle('hover:bg-indigo-700', this.problemsVisible)
    this.toggleProblemsBtnTarget.classList.toggle('bg-white', !this.problemsVisible)
    this.toggleProblemsBtnTarget.classList.toggle('text-gray-700', !this.problemsVisible)
    this.toggleProblemsBtnTarget.classList.toggle('border-gray-300', !this.problemsVisible)
    this.toggleProblemsBtnTarget.classList.toggle('hover:bg-gray-100', !this.problemsVisible)
  }

  showProblemMarkers() {
    this.map.setLayoutProperty('problems', 'visibility', 'visible')
  }

  hideProblemMarkers() {
    this.map.setLayoutProperty('problems', 'visibility', 'none')
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────────

  // Padding for fitting bounds, shrunk on small maps: if the padding doesn't fit,
  // MapLibre gives up and leaves the map at its world view.
  fitPadding(max) {
    const { width, height } = this.mapContainerTarget.getBoundingClientRect()
    return Math.max(0, Math.min(max, Math.floor(Math.min(width, height) / 5)))
  }

  clearVertexMarkers() {
    this.unpickVertex()
    this.vertexMarkers.forEach(m => m.remove())
    this.vertexMarkers = []
    this.midpointMarkers.forEach(m => m.remove())
    this.midpointMarkers = []
  }

  updateCount(n) {
    this.countTarget.textContent = n
    this.countSuffixTarget.textContent = n === 1 ? '' : 's'
  }

  setStatus(msg) {
    this.statusTarget.textContent = msg
  }

  showToast(message, isError = false) {
    const toast = document.createElement('div')
    const bg = isError ? 'bg-red-600' : 'bg-granite'
    toast.className = `fixed bottom-4 right-4 ${bg} text-white text-sm px-4 py-2 rounded shadow-lg z-50`
    toast.textContent = message
    document.body.appendChild(toast)
    setTimeout(() => {
      toast.style.transition = 'opacity 0.3s'
      toast.style.opacity = '0'
      setTimeout(() => toast.remove(), 300)
    }, 2700)
  }

  // ─── Basemap switcher ─────────────────────────────────────────────────────────

  get basemapSources() {
    return {
      esri: {
        tiles: ['https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'],
        attribution: 'Satellite imagery © Esri',
      },
      maptiler: {
        tiles: [`https://api.maptiler.com/tiles/satellite/{z}/{x}/{y}.jpg?key=${this.maptilerKeyValue}`],
        attribution: 'Satellite imagery © MapTiler',
      },
      bing: {
        tiles: [`https://atlas.microsoft.com/map/tile?api-version=2.1&tilesetId=microsoft.imagery&zoom={z}&x={x}&y={y}&subscription-key=${this.azureKeyValue}`],
        attribution: 'Satellite imagery © Microsoft (Bing)',
      },
      mapbox: {
        tiles: [`https://api.mapbox.com/v4/mapbox.satellite/{z}/{x}/{y}.jpg90?access_token=${this.mapboxKeyValue}`],
        attribution: 'Satellite imagery © Mapbox',
      },
    }
  }

  // Devon County Council's Environment Viewer in a new tab, centred on the selected boulder
  // (or the middle of the map) at roughly the same scale. A link out only: the council's
  // licence lets us view its aerials on its own site, not copy or re-serve them.
  openCouncilAerials() {
    const feature = this.bouldersGeoJSON.features.find(f => f.properties.boulderId == this.selectedBoulderId)
    let lng, lat
    if (feature) {
      const ring = feature.geometry.coordinates[0]
      lng = ring.reduce((sum, c) => sum + c[0], 0) / ring.length
      lat = ring.reduce((sum, c) => sum + c[1], 0) / ring.length
    } else {
      ({ lng, lat } = this.map.getCenter())
    }
    // MapLibre's 512px tiles: metres per pixel at this zoom, then a map scale at 96 dpi
    const metresPerPixel = 40075016.686 * Math.cos(lat * Math.PI / 180) / (512 * 2 ** this.map.getZoom())
    const scale = Math.max(500, Math.round(metresPerPixel * 96 / 0.0254))
    const point = `${lng.toFixed(6)},${lat.toFixed(6)}`
    const params = new URLSearchParams({ id: 'fdc6c6d25dde46f09a81a725c53a7034', center: point, scale })
    if (feature) params.set('marker', `${point},4326,${(feature.properties.name || 'Boulder').replace(/,/g, ' ')},,`)
    window.open(`https://map.devon.gov.uk/portal/apps/webappviewer/index.html?${params}`, '_blank', 'noopener')
  }

  setBasemap(event) {
    const name = event.currentTarget.dataset.basemap
    const source = this.basemapSources[name]
    if (!source) return
    this.map.getSource('satellite').setTiles(source.tiles)
    localStorage.setItem('boulder-editor-basemap', name)
    this.highlightBasemapBtn(name)
    if (this.hasAttributionTarget) {
      this.attributionTarget.textContent = source.attribution + '. Boulder data saves automatically on finish.'
    }
  }

  highlightBasemapBtn(name) {
    this.basemapBtnTargets.forEach(btn => {
      const active = btn.dataset.basemap === name
      btn.classList.toggle('bg-gray-800', active)
      btn.classList.toggle('text-white', active)
      btn.classList.toggle('border-gray-800', active)
      btn.classList.toggle('bg-white', !active)
      btn.classList.toggle('text-gray-700', !active)
      btn.classList.toggle('border-gray-300', !active)
    })
  }

  // ─── LiDAR boulder suggestions ────────────────────────────────────────────────
  // Analyses EA LiDAR for the current view (see lidar_suggestions.js) and shows
  // likely boulders: amber where nothing is mapped, green where they overlap an
  // existing boulder whose outline may need correcting.

  async suggestBoulders() {
    this.suggestBtnTarget.disabled = true
    this.suggestStatusTarget.textContent = 'Fetching LiDAR…'
    try {
      // Loaded on demand so a CDN problem can't break the rest of the editor
      const { suggestBoulders } = await import('lidar_suggestions')
      const b = this.map.getBounds()
      const boulders = this.bouldersGeoJSON.features.map(f => ({
        id: f.properties.boulderId, ring: f.geometry.coordinates[0],
      }))
      this.suggestions = await suggestBoulders(
        { west: b.getWest(), south: b.getSouth(), east: b.getEast(), north: b.getNorth() }, boulders
      )
      this.renderSuggestions()
      const overlapping = this.suggestions.filter(s => s.overlaps.length).length
      this.suggestStatusTarget.textContent = this.suggestions.length
        ? `${this.suggestions.length - overlapping} new, ${overlapping} overlapping. Click one to use it.`
        : 'No likely boulders found in this view.'
      if (this.selectedBoulderId != null) {
        this.useLidarBtnTarget.classList.toggle('hidden', !this.suggestionFor(this.selectedBoulderId))
      }
      this.updateAddAllButton()
    } catch (error) {
      this.suggestStatusTarget.textContent = ''
      this.showToast(error.message || 'Could not fetch LiDAR', true)
    } finally {
      this.suggestBtnTarget.disabled = false
      this.suggestBtnTarget.textContent = 'Suggest again for this view'
    }
  }

  renderSuggestions() {
    this.map.getSource('suggestions').setData({
      type: 'FeatureCollection',
      features: this.suggestions.map((s, index) => s && ({
        type: 'Feature',
        properties: { index, overlaps: s.overlaps.length > 0 },
        geometry: { type: 'Polygon', coordinates: [[...s.coordinates, s.coordinates[0]]] },
      })).filter(Boolean),
    })
  }

  // The suggestion that overlaps this boulder most (suggestions list overlaps biggest first)
  suggestionFor(boulderId) {
    return this.suggestions.find(s => s && s.overlaps[0] == boulderId) ||
      this.suggestions.find(s => s && s.overlaps.includes(Number(boulderId)))
  }

  showSuggestionPopup(index, lngLat) {
    const s = this.suggestions[index]
    if (!s) return
    const el = document.createElement('div')
    el.className = 'text-xs flex flex-col gap-1.5'
    const info = document.createElement('p')
    info.className = 'text-gray-600'
    info.textContent = `LiDAR suggestion · ${s.area} m² · up to ${s.height} m high`
    el.appendChild(info)
    if (s.overlaps.length > 1) {
      const warning = document.createElement('p')
      warning.className = 'text-amber-700'
      warning.textContent = `Covers ${s.overlaps.map(id => `#${id}`).join(', ')}: may be several rocks merged into one shape.`
      el.appendChild(warning)
    }
    const button = (label, primary, onClick) => {
      const b = document.createElement('button')
      b.type = 'button'
      b.textContent = label
      b.className = primary
        ? 'px-2 py-1 rounded bg-granite text-white hover:bg-granite-dark'
        : 'px-2 py-1 rounded border border-gray-300 bg-white text-gray-700 hover:bg-gray-100'
      b.addEventListener('click', () => { this.suggestionPopup.remove(); onClick() })
      el.appendChild(b)
    }
    s.overlaps.slice(0, 3).forEach(id =>
      button(`Replace outline of #${id}`, true, () => this.replaceWithSuggestion(id, s))
    )
    const pinned = s.overlaps.length === 0 ? this.pinnedNameFor(s) : null
    if (pinned) button(`Add as ${pinned.name} (pin)`, true, () => this.addSuggestion(index, pinned))
    button('Add as new boulder', s.overlaps.length === 0 && !pinned, () => this.addSuggestion(index))
    if (this.unplaced.length) {
      const select = document.createElement('select')
      select.className = 'px-1 py-1 rounded border border-gray-300 bg-white text-gray-700'
      select.append(new Option('Add as a listed boulder…', ''), ...this.unplaced.map(u => new Option(u.name, u.id)))
      select.addEventListener('change', () => {
        const listed = this.unplaced.find(u => u.id === Number(select.value))
        if (!listed) return
        this.suggestionPopup.remove()
        this.addSuggestion(index, listed)
      })
      el.appendChild(select)
    }

    this.suggestionPopup?.remove()
    this.suggestionPopup = new maplibregl.Popup({ offset: 8, maxWidth: '220px' })
      .setLngLat(lngLat).setDOMContent(el).addTo(this.map)
  }

  async addSuggestion(index, placing = null) {
    const s = this.suggestions[index]
    const id = await this.createBoulder(s.coordinates, placing)
    if (id == null) return
    this.suggestions[index] = null
    this.renderSuggestions()
    this.updateAddAllButton()
    this.selectBoulder(id)
    this.setStatus(`${this.labelFor(id)} added from LiDAR. Tidy the corners, then Save changes.`)
  }

  // Indexes of the amber suggestions (nothing mapped there yet)
  unmappedSuggestions() {
    return (this.suggestions || []).flatMap((s, index) => (s && s.overlaps.length === 0) ? [index] : [])
  }

  updateAddAllButton() {
    const count = this.unmappedSuggestions().length
    this.addAllBtnTarget.classList.toggle('hidden', count === 0)
    this.addAllBtnTarget.textContent = `Add all ${count} unmapped as boulders`
  }

  // Saves every amber suggestion as a new boulder, one at a time, stopping at the first failure
  async addAllUnmapped() {
    const indexes = this.unmappedSuggestions()
    if (!indexes.length) return
    const pinned = new Set(indexes.map(index => this.pinnedNameFor(this.suggestions[index])?.id).filter(Boolean)).size
    if (!confirm(`Add ${indexes.length} new boulder${indexes.length === 1 ? '' : 's'} from LiDAR?` +
      (pinned ? ` About ${pinned} will take the name of the pin on them.` : '') +
      ' Check the amber shapes first: walls and parked cars can show up as rock.')) return

    this.addAllBtnTarget.disabled = true
    this.suggestBtnTarget.disabled = true
    let added = 0
    try {
      for (const index of indexes) {
        this.suggestStatusTarget.textContent = `Adding ${added + 1}/${indexes.length}…`
        // A pin on the shape names it (each listed name is used once: it leaves the list when placed)
        const id = await this.createBoulder(this.suggestions[index].coordinates, this.pinnedNameFor(this.suggestions[index]))
        if (id == null) break
        this.suggestions[index] = null
        added++
      }
    } finally {
      this.renderSuggestions()
      this.addAllBtnTarget.disabled = false
      this.suggestBtnTarget.disabled = false
      this.updateAddAllButton()
      this.suggestStatusTarget.textContent = added === indexes.length
        ? `Added ${added} boulder${added === 1 ? '' : 's'}. Tidy any corners, then Save changes.`
        : `Added ${added} of ${indexes.length}; stopped after an error.`
    }
  }

  replaceWithSuggestion(boulderId, suggestion) {
    if (this.selectedBoulderId != boulderId) this.selectBoulder(boulderId)
    this.placeVertexMarkers(suggestion.coordinates)
    this.refreshSelectedPolygon()
    this.dirty = true
    const others = suggestion.overlaps.filter(id => id != boulderId)
    const merged = others.length
      ? ` It also covers ${others.map(id => `#${id}`).join(', ')}, so it may be several rocks: trim it before saving.`
      : ''
    this.setStatus(`LiDAR outline for #${boulderId}.${merged} Save changes to keep it, or click the boulder again to undo.`)
  }

  useLidarOutline() {
    const s = this.suggestionFor(this.selectedBoulderId)
    if (s) this.replaceWithSuggestion(this.selectedBoulderId, s)
  }

  // ─── LiDAR hillshade overlay ──────────────────────────────────────────────────
  // Environment Agency 1 m LiDAR surface model (first return), rendered as hillshade
  // by the EA's WMS. Boulders show as crisp relief with no shadows or lichen to
  // confuse things. England only; served direct from the EA, no key needed.

  addLidarLayer() {
    this.map.addSource('lidar', {
      type: 'raster',
      tiles: [
        'https://environment.data.gov.uk/spatialdata/lidar-composite-digital-surface-model-first-return-dsm-1m/wms' +
        '?service=WMS&version=1.3.0&request=GetMap&layers=Lidar_Composite_Hillshade_FZ_DSM_1m&styles=' +
        '&crs=EPSG:3857&bbox={bbox-epsg-3857}&width=256&height=256&format=image/png'
      ],
      tileSize: 256,
      // z17 tiles are ~0.75 m/px, close to the 1 m data. Deeper zooms come back from
      // the WMS as blocky 1 m squares; over-zooming z17 lets MapLibre smooth them.
      // Larger bboxes (512px tiles, lower zooms) get a coarser, re-stretched render
      // from the WMS with visible seams, so stay at 256px.
      maxzoom: 17,
      attribution: 'LiDAR © Environment Agency (OGL v3)',
    })

    const opacity = parseFloat(localStorage.getItem('boulder-editor-lidar-opacity') ?? '0.6')
    const visible = localStorage.getItem('boulder-editor-lidar') === 'on'
    this.map.addLayer({
      id: 'lidar',
      type: 'raster',
      source: 'lidar',
      layout: { visibility: visible ? 'visible' : 'none' },
      paint: { 'raster-opacity': opacity },
    })
    if (this.hasLidarOpacityTarget) this.lidarOpacityTarget.value = Math.round(opacity * 100)
    this.highlightLidarBtn(visible)
  }

  toggleLidar() {
    const visible = this.map.getLayoutProperty('lidar', 'visibility') !== 'visible'
    this.map.setLayoutProperty('lidar', 'visibility', visible ? 'visible' : 'none')
    localStorage.setItem('boulder-editor-lidar', visible ? 'on' : 'off')
    this.highlightLidarBtn(visible)
  }

  setLidarOpacity() {
    const opacity = this.lidarOpacityTarget.value / 100
    this.map.setPaintProperty('lidar', 'raster-opacity', opacity)
    localStorage.setItem('boulder-editor-lidar-opacity', opacity)
  }

  highlightLidarBtn(active) {
    if (!this.hasLidarBtnTarget) return
    const btn = this.lidarBtnTarget
    btn.textContent = active ? 'LiDAR on' : 'LiDAR off'
    btn.classList.toggle('bg-gray-800', active)
    btn.classList.toggle('text-white', active)
    btn.classList.toggle('border-gray-800', active)
    btn.classList.toggle('bg-white', !active)
    btn.classList.toggle('text-gray-700', !active)
    btn.classList.toggle('border-gray-300', !active)
    this.lidarOpacityTarget.disabled = !active
  }

  // ─── Tracing image ────────────────────────────────────────────────────────────
  // An image from the admin's own computer (a drone photo, a sketch map) pinned to the
  // map at four corners, to trace outlines from. It lives only in this page: drawn to a
  // canvas and shown as a MapLibre canvas source, never uploaded or stored, so it's gone
  // on reload. (A canvas rather than a blob: URL also keeps it inside the CSP.)

  static OVERLAY_MAX_SIDE = 4096 // bigger textures render black on some iPads and laptops

  chooseOverlayImage() {
    this.imageInputTarget.click()
  }

  loadOverlayImage() {
    const file = this.imageInputTarget.files[0]
    this.imageInputTarget.value = '' // so choosing the same file again still fires change
    if (!file) return
    const url = URL.createObjectURL(file)
    const img = new Image()
    img.onload = () => {
      URL.revokeObjectURL(url)
      this.showOverlayImage(img)
    }
    img.onerror = () => {
      URL.revokeObjectURL(url)
      this.showToast("Couldn't read that image. Try a JPEG or PNG", true)
    }
    img.src = url
  }

  showOverlayImage(img) {
    // Downscaled copy on a canvas; drawing it also applies the photo's EXIF rotation
    const scale = Math.min(1, this.constructor.OVERLAY_MAX_SIDE / Math.max(img.naturalWidth, img.naturalHeight))
    const canvas = document.createElement('canvas')
    canvas.width = Math.max(1, Math.round(img.naturalWidth * scale))
    canvas.height = Math.max(1, Math.round(img.naturalHeight * scale))
    canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height)

    this.removeOverlayImage()
    this.overlayCanvas = canvas
    this.overlayCorners = this.initialOverlayCorners(canvas.width / canvas.height)

    const opacity = parseFloat(localStorage.getItem('boulder-editor-image-opacity') ?? '0.6')
    this.imageOpacityTarget.value = Math.round(opacity * 100)
    this.map.addSource('overlay-image', {
      type: 'canvas', canvas, animate: false, coordinates: this.overlayCorners,
    })
    // Over the satellite and LiDAR, under suggestions and outlines; a raster layer
    // takes no clicks, so tracing and selecting work straight through it
    this.map.addLayer({
      id: 'overlay-image',
      type: 'raster',
      source: 'overlay-image',
      paint: { 'raster-opacity': opacity, 'raster-fade-duration': 0 },
    }, this.map.getLayer('suggestions-fill') ? 'suggestions-fill' : undefined)

    this.imageControlsTarget.classList.remove('hidden')
    this.imageChooseBtnTarget.textContent = 'Replace image…'
    this.setOverlayAdjusting(true)
    this.setStatus('Drag the middle handle to move the image, the corners to fit it')
  }

  // Centred in the view, at the image's shape, about 60% of the view: [tl, tr, br, bl]
  initialOverlayCorners(aspect) {
    const { clientWidth: w, clientHeight: h } = this.map.getContainer()
    let boxW = w * 0.6
    let boxH = boxW / aspect
    if (boxH > h * 0.6) { boxH = h * 0.6; boxW = boxH * aspect }
    const x0 = (w - boxW) / 2, y0 = (h - boxH) / 2
    return [[x0, y0], [x0 + boxW, y0], [x0 + boxW, y0 + boxH], [x0, y0 + boxH]]
      .map(p => this.map.unproject(p).toArray())
  }

  setOverlayOpacity() {
    const opacity = this.imageOpacityTarget.value / 100
    if (this.map.getLayer('overlay-image')) this.map.setPaintProperty('overlay-image', 'raster-opacity', opacity)
    localStorage.setItem('boulder-editor-image-opacity', opacity)
  }

  toggleOverlayAdjust() {
    this.setOverlayAdjusting(!this.overlayHandles)
  }

  // Handles only while adjusting: left on the map they'd sit over boulder corners and
  // swallow the clicks meant for tracing
  setOverlayAdjusting(on) {
    this.overlayHandles?.forEach(m => m.remove())
    this.overlayHandles = null
    if (on && this.overlayCorners) {
      const corners = this.overlayCorners.map((corner, i) => {
        const el = document.createElement('div')
        el.className = 'w-3.5 h-3.5 bg-white border-2 border-fuchsia-600 shadow cursor-crosshair'
        el.title = 'Drag to stretch or turn the image'
        const marker = new maplibregl.Marker({ element: el, draggable: true }).setLngLat(corner).addTo(this.map)
        marker.on('drag', () => {
          this.overlayCorners[i] = marker.getLngLat().toArray()
          this.updateOverlayCorners({ skip: marker })
        })
        return marker
      })

      const el = document.createElement('div')
      el.className = 'w-7 h-7 rounded-full bg-fuchsia-600/80 border-2 border-white shadow text-white text-sm leading-6 text-center cursor-move select-none'
      el.textContent = '✥'
      el.title = 'Drag to move the image'
      const move = new maplibregl.Marker({ element: el, draggable: true }).setLngLat(this.overlayCentre()).addTo(this.map)
      // Moves in screen pixels, so the image keeps its shape on screen
      move.on('dragstart', () => {
        this.moveStart = { at: this.map.project(move.getLngLat()), corners: this.overlayCorners.map(c => this.map.project(c)) }
      })
      move.on('drag', () => {
        const at = this.map.project(move.getLngLat())
        const dx = at.x - this.moveStart.at.x, dy = at.y - this.moveStart.at.y
        this.overlayCorners = this.moveStart.corners.map(p => this.map.unproject([p.x + dx, p.y + dy]).toArray())
        this.updateOverlayCorners({ skip: move })
      })
      this.overlayHandles = [...corners, move]
    }
    if (this.hasImageAdjustBtnTarget) {
      const active = !!this.overlayHandles
      const btn = this.imageAdjustBtnTarget
      btn.textContent = active ? 'Done moving' : 'Move / resize'
      btn.classList.toggle('bg-gray-800', active)
      btn.classList.toggle('text-white', active)
      btn.classList.toggle('border-gray-800', active)
      btn.classList.toggle('bg-white', !active)
      btn.classList.toggle('text-gray-700', !active)
      btn.classList.toggle('border-gray-300', !active)
    }
  }

  overlayCentre() {
    const c = this.overlayCorners
    return [c.reduce((s, p) => s + p[0], 0) / 4, c.reduce((s, p) => s + p[1], 0) / 4]
  }

  // Pushes the corners to the map and keeps the handles on them (except the one being dragged)
  updateOverlayCorners({ skip } = {}) {
    this.map.getSource('overlay-image')?.setCoordinates(this.overlayCorners)
    this.overlayHandles?.forEach((m, i) => {
      if (m !== skip) m.setLngLat(i < 4 ? this.overlayCorners[i] : this.overlayCentre())
    })
  }

  removeOverlayImage() {
    this.overlayHandles?.forEach(m => m.remove())
    this.overlayHandles = null
    if (this.map.getLayer('overlay-image')) this.map.removeLayer('overlay-image')
    if (this.map.getSource('overlay-image')) this.map.removeSource('overlay-image')
    this.overlayCanvas = null
    this.overlayCorners = null
    if (this.hasImageControlsTarget) this.imageControlsTarget.classList.add('hidden')
    if (this.hasImageChooseBtnTarget) this.imageChooseBtnTarget.textContent = 'Import image…'
  }

  disconnect() {
    document.removeEventListener('keydown', this._onKeyDown)
    this.overlayHandles?.forEach(m => m.remove())
    this.map?.remove()
  }
}
