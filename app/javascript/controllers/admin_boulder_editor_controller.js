import { Controller } from '@hotwired/stimulus'

// States: 'idle' | 'drawing' | 'selected'

export default class extends Controller {
  static targets = [
    'mapContainer', 'drawBtn', 'drawingActions', 'selectedActions',
    'status', 'count', 'countSuffix', 'boulderList', 'basemapBtn', 'attribution',
    'toggleProblemsBtn',
  ]
  static values = {
    geojsonUrl: String,
    createUrl: String,
    updateUrlTemplate: String,
    deleteUrlTemplate: String,
    bounds: Object,
    maptilerKey: String,
    azureKey: String,
    mapboxKey: String,
  }

  connect() {
    if (typeof maplibregl === 'undefined') {
      window.addEventListener('maplibre-ready', () => this.connect(), { once: true })
      return
    }

    this.state = 'idle'
    this.drawCoords = []
    this.drawMarkers = []
    this.vertexMarkers = []
    this.selectedBoulderId = null
    this.bouldersGeoJSON = { type: 'FeatureCollection', features: [] }
    this.problemFeatures = []
    this.problemsVisible = false

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
      fitBoundsOptions: { padding: 60 },
    })

    this.map.addControl(new maplibregl.NavigationControl())
    this.map.addControl(new maplibregl.ScaleControl({ maxWidth: 100, unit: 'metric' }))

    this.map.on('load', () => {
      this.loadData()
      const saved = localStorage.getItem('boulder-editor-basemap')
      if (saved && this.basemapSources[saved]) {
        this.map.getSource('satellite').setTiles(this.basemapSources[saved].tiles)
        this.highlightBasemapBtn(saved)
      } else {
        this.highlightBasemapBtn('esri')
      }
    })

    // Keyboard: Escape cancels drawing
    this._onKeyDown = (e) => { if (e.key === 'Escape') this.cancelDrawing() }
    document.addEventListener('keydown', this._onKeyDown)
  }

  // ─── Data loading ───────────────────────────────────────────────────────────

  loadData() {
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
          '#888888'  // grey otherwise
        ],
        'fill-opacity': 0.5,
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
        this.updateCount(this.bouldersGeoJSON.features.length)
      })
  }

  // ─── Drawing ────────────────────────────────────────────────────────────────

  startDrawing() {
    this.deselect()
    this.state = 'drawing'
    this.drawCoords = []
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
    this.drawCoords.push([e.lngLat.lng, e.lngLat.lat])

    // Add a small yellow dot marker at this vertex
    const el = document.createElement('div')
    el.className = 'w-2 h-2 rounded-full bg-amber-400 border border-white'
    const marker = new maplibregl.Marker({ element: el }).setLngLat([e.lngLat.lng, e.lngLat.lat]).addTo(this.map)
    this.drawMarkers = this.drawMarkers || []
    this.drawMarkers.push(marker)

    // Update preview line
    this.map.getSource('draw-preview').setData({
      type: 'Feature',
      geometry: { type: 'LineString', coordinates: this.drawCoords }
    })
  }

  finishPolygon(e) {
    e.preventDefault?.()
    if (this.state !== 'drawing') return

    // dblclick fires after 2 click events — drop the last coord added by the 2nd click
    const coordinates = this.drawCoords.slice(0, -1)

    if (coordinates.length < 3) {
      this.showToast('Need at least 3 points', true)
      return
    }
    this.exitDrawingMode()

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    fetch(this.createUrlValue, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': csrfToken,
      },
      body: JSON.stringify({ coordinates }),
    })
      .then(r => r.json())
      .then(data => {
        if (data.error) { this.showToast(data.error, true); return }

        // Add new feature to local GeoJSON
        const closed = [...coordinates, coordinates[0]]
        const feature = {
          type: 'Feature',
          id: data.id,
          properties: { boulderId: data.id },
          geometry: { type: 'Polygon', coordinates: [closed] }
        }
        this.bouldersGeoJSON.features.push(feature)
        this.map.getSource('boulders').setData(this.bouldersGeoJSON)

        const newCount = this.bouldersGeoJSON.features.length
        this.updateCount(newCount)
        this.renderBoulderList()
        this.showToast(`Boulder #${data.id} saved`)
      })
      .catch(() => this.showToast('Network error — not saved', true))
  }

  cancelDrawing() {
    if (this.state !== 'drawing') return
    this.exitDrawingMode()
    this.setStatus('Cancelled')
    setTimeout(() => this.setStatus('Click a polygon to select'), 1500)
  }

  exitDrawingMode() {
    this.state = 'idle'
    this.drawCoords = []
    this.map.getCanvas().style.cursor = ''
    this.map.off('click', this._onMapClick)
    this.map.off('dblclick', this._onMapDblClick)
    this.map.doubleClickZoom.enable()

    // Remove draw vertex dot markers
    ;(this.drawMarkers || []).forEach(m => m.remove())
    this.drawMarkers = []

    // Clear preview line
    this.map.getSource('draw-preview').setData({
      type: 'Feature', geometry: { type: 'LineString', coordinates: [] }
    })

    this.drawingActionsTarget.classList.add('hidden')
    this.drawBtnTarget.classList.remove('hidden')
  }

  // ─── Selection & editing ─────────────────────────────────────────────────────

  selectBoulder(boulderId) {
    this.clearVertexMarkers()

    // Deselect previous
    if (this.selectedBoulderId != null) {
      this.map.setFeatureState({ source: 'boulders', id: this.selectedBoulderId }, { selected: false })
    }

    this.selectedBoulderId = boulderId
    this.state = 'selected'
    this.map.setFeatureState({ source: 'boulders', id: boulderId }, { selected: true })

    this.selectedActionsTarget.classList.remove('hidden')
    this.setStatus(`Boulder #${boulderId} selected`)

    // Find the feature and place draggable vertex markers
    const feature = this.bouldersGeoJSON.features.find(
      f => f.properties.boulderId == boulderId
    )
    if (!feature) return

    const ring = feature.geometry.coordinates[0]
    // Skip last coord if it closes the ring (equals first)
    const coords = ring[0][0] === ring[ring.length - 1][0] && ring[0][1] === ring[ring.length - 1][1]
      ? ring.slice(0, -1)
      : ring

    coords.forEach(([lng, lat], i) => {
      const el = document.createElement('div')
      el.className = 'w-3 h-3 rounded-full bg-blue-500 border-2 border-white cursor-move shadow'

      const marker = new maplibregl.Marker({ element: el, draggable: true })
        .setLngLat([lng, lat])
        .addTo(this.map)

      // Live-update polygon outline while dragging
      marker.on('drag', () => this.refreshSelectedPolygon())

      this.vertexMarkers.push(marker)
    })
  }

  refreshSelectedPolygon() {
    const feature = this.bouldersGeoJSON.features.find(
      f => f.properties.boulderId == this.selectedBoulderId
    )
    if (!feature) return

    const coords = this.vertexMarkers.map(m => {
      const ll = m.getLngLat()
      return [ll.lng, ll.lat]
    })
    const closed = [...coords, coords[0]]
    feature.geometry.coordinates = [closed]
    this.map.getSource('boulders').setData(this.bouldersGeoJSON)
  }

  deselect() {
    if (this.selectedBoulderId != null) {
      this.map.setFeatureState({ source: 'boulders', id: this.selectedBoulderId }, { selected: false })
      this.selectedBoulderId = null
    }
    this.state = 'idle'
    this.clearVertexMarkers()
    this.selectedActionsTarget.classList.add('hidden')
    this.setStatus('Click a polygon to select')
  }

  saveSelected() {
    if (!this.selectedBoulderId || this.vertexMarkers.length < 3) return

    const coordinates = this.vertexMarkers.map(m => {
      const ll = m.getLngLat()
      return [ll.lng, ll.lat]
    })

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
        if (data.error) { this.showToast(data.error, true); return }
        this.showToast(`Boulder #${this.selectedBoulderId} saved`)
      })
      .catch(() => this.showToast('Network error — not saved', true))
  }

  deleteSelected() {
    if (!this.selectedBoulderId) return
    if (!confirm(`Delete boulder #${this.selectedBoulderId}?`)) return

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

  // ─── Sidebar ─────────────────────────────────────────────────────────────────

  renderBoulderList() {
    const ids = this.bouldersGeoJSON.features.map(f => f.properties.boulderId).sort((a, b) => a - b)
    if (ids.length === 0) {
      this.boulderListTarget.innerHTML = '<p class="italic text-gray-400 py-2">No boulders yet.</p>'
      return
    }
    this.boulderListTarget.innerHTML = ids.map(id =>
      `<div class="py-1 cursor-pointer hover:text-emerald-700" data-boulder-id="${id}" data-action="click->admin-boulder-editor#sidebarClick">
        Boulder #${id}
      </div>`
    ).join('')
  }

  sidebarClick(e) {
    const id = parseInt(e.currentTarget.dataset.boulderId, 10)
    if (this.state !== 'idle' && this.state !== 'selected') return
    this.deselect()
    this.selectBoulder(id)

    // Fly to the boulder
    const feature = this.bouldersGeoJSON.features.find(f => f.properties.boulderId == id)
    if (feature) {
      const coords = feature.geometry.coordinates[0]
      const lngs = coords.map(c => c[0])
      const lats = coords.map(c => c[1])
      this.map.fitBounds(
        [[Math.min(...lngs), Math.min(...lats)], [Math.max(...lngs), Math.max(...lats)]],
        { padding: 80, maxZoom: 20 }
      )
    }
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

  clearVertexMarkers() {
    this.vertexMarkers.forEach(m => m.remove())
    this.vertexMarkers = []
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
    const bg = isError ? 'bg-red-600' : 'bg-emerald-600'
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

  disconnect() {
    document.removeEventListener('keydown', this._onKeyDown)
    this.map?.remove()
  }
}
