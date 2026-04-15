import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['mapContainer', 'problem', 'count', 'sidebar']
  static values = {
    geojsonUrl: String,
    updateUrlTemplate: String,
    bounds: Object,
  }

  connect() {
    this.draggedProblemId = null
    this.draggedProblemName = null
    this.markers = {}

    const bounds = this.boundsValue
    const sw = bounds.south_west
    const ne = bounds.north_east

    this.map = new maplibregl.Map({
      container: this.mapContainerTarget,
      style: 'https://tiles.openfreemap.org/styles/liberty',
      bounds: [[sw.lng, sw.lat], [ne.lng, ne.lat]],
      fitBoundsOptions: { padding: 60 },
    })

    this.map.addControl(new maplibregl.NavigationControl())
    this.map.addControl(new maplibregl.ScaleControl({ maxWidth: 100, unit: 'metric' }))

    this.map.on('load', () => this.loadData())
  }

  loadData() {
    this.map.addSource('area-data', {
      type: 'geojson',
      data: this.geojsonUrlValue,
    })

    // Boulder fill polygons
    this.map.addLayer({
      id: 'boulders',
      type: 'fill',
      source: 'area-data',
      paint: { 'fill-color': '#888', 'fill-opacity': 0.65 },
      filter: ['==', ['geometry-type'], 'Polygon'],
    })

    this.map.addLayer({
      id: 'boulders-outline',
      type: 'line',
      source: 'area-data',
      paint: { 'line-color': '#444', 'line-width': 1.5 },
      filter: ['==', ['geometry-type'], 'Polygon'],
    })

    // Add draggable markers for already-located problems
    fetch(this.geojsonUrlValue)
      .then(r => r.json())
      .then(data => {
        data.features.forEach(f => {
          if (f.geometry.type === 'Point') {
            const [lng, lat] = f.geometry.coordinates
            const id = f.properties.problemId
            const name = f.properties.name
            this.addMarker(id, name, lng, lat)
          }
        })
      })
  }

  addMarker(problemId, name, lng, lat) {
    const el = document.createElement('div')
    el.className = [
      'w-4 h-4 rounded-full border-2 border-white cursor-move shadow-md',
      'bg-emerald-600 hover:bg-emerald-700 transition-colors',
    ].join(' ')
    el.title = name

    const popup = new maplibregl.Popup({ offset: 10 }).setText(name)

    const marker = new maplibregl.Marker({ element: el, draggable: true })
      .setLngLat([lng, lat])
      .setPopup(popup)
      .addTo(this.map)

    el.addEventListener('mouseenter', () => popup.addTo(this.map))
    el.addEventListener('mouseleave', () => popup.remove())

    marker.on('dragend', () => {
      const lngLat = marker.getLngLat()
      this.patchLocation(problemId, lngLat.lat, lngLat.lng)
        .then(ok => {
          if (ok) this.showToast(`Saved: ${name}`)
        })
    })

    this.markers[problemId] = marker
  }

  // Sidebar drag events
  dragStart(event) {
    this.draggedProblemId = event.currentTarget.dataset.problemId
    this.draggedProblemName = event.currentTarget.dataset.problemName
    event.dataTransfer.effectAllowed = 'move'
    event.currentTarget.classList.add('opacity-50')
  }

  dragOver(event) {
    event.preventDefault()
    event.dataTransfer.dropEffect = 'move'
  }

  drop(event) {
    event.preventDefault()

    const problemId = this.draggedProblemId
    const problemName = this.draggedProblemName
    this.draggedProblemId = null
    this.draggedProblemName = null

    if (!problemId) return

    const rect = this.mapContainerTarget.getBoundingClientRect()
    const x = event.clientX - rect.left
    const y = event.clientY - rect.top
    const lngLat = this.map.unproject([x, y])

    this.patchLocation(problemId, lngLat.lat, lngLat.lng).then(ok => {
      if (!ok) return

      // Remove from sidebar
      const el = this.problemTargets.find(t => t.dataset.problemId === problemId)
      if (el) {
        el.remove()
        this.updateCount(-1)
      }

      // Add marker on map
      this.addMarker(problemId, problemName, lngLat.lng, lngLat.lat)
      this.showToast(`Placed: ${problemName}`)
    })
  }

  // AJAX helpers
  patchLocation(problemId, lat, lng) {
    const url = this.updateUrlTemplateValue.replace('PROBLEM_ID', problemId)
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    return fetch(url, {
      method: 'PATCH',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': csrfToken,
      },
      body: JSON.stringify({ problem: { lat, lon: lng } }),
    }).then(r => {
      if (!r.ok) {
        this.showToast('Failed to save — check console', true)
        return false
      }
      return true
    }).catch(err => {
      console.error('Failed to save location:', err)
      this.showToast('Network error — changes not saved', true)
      return false
    })
  }

  // UI helpers
  updateCount(delta) {
    if (!this.hasCountTarget) return
    const current = parseInt(this.countTarget.textContent, 10)
    this.countTarget.textContent = current + delta
  }

  showToast(message, isError = false) {
    const toast = document.createElement('div')
    const bg = isError ? 'bg-red-600' : 'bg-emerald-600'
    toast.className = `fixed bottom-4 right-4 ${bg} text-white text-sm px-4 py-2 rounded shadow-lg z-50 transition-opacity`
    toast.textContent = message
    document.body.appendChild(toast)
    setTimeout(() => {
      toast.classList.add('opacity-0')
      setTimeout(() => toast.remove(), 300)
    }, 2700)
  }

  disconnect() {
    this.map?.remove()
  }
}
