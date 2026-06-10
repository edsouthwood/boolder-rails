import { Controller } from '@hotwired/stimulus'

// A small MapLibre map with a single draggable marker that reads/writes the
// contribution's latitude/longitude inputs. Stays in sync with EXIF auto-fill
// (the contribution-photo controller dispatches `input` on those fields).
export default class extends Controller {
  static targets = ['map', 'latField', 'lonField']
  static values = { bounds: Object }

  connect() {
    if (typeof maplibregl === 'undefined') {
      window.addEventListener('maplibre-ready', () => this.connect(), { once: true })
      return
    }
    if (this.map) return // guard against double-connect after maplibre-ready

    const b = this.boundsValue
    const sw = b.south_west
    const ne = b.north_east

    this.map = new maplibregl.Map({
      container: this.mapTarget,
      style: 'https://tiles.openfreemap.org/styles/liberty',
      bounds: [[sw.lng, sw.lat], [ne.lng, ne.lat]],
      fitBoundsOptions: { padding: 40, maxZoom: 17 },
    })
    this.map.addControl(new maplibregl.NavigationControl())
    this.marker = null

    // Drop/move the marker by clicking the map.
    this.map.on('click', (e) => this.placeMarker(e.lngLat.lng, e.lngLat.lat, true))

    // Sync the marker when the fields change (manual typing or EXIF auto-fill).
    this.onFieldInput = () => this.syncFromFields()
    this.latFieldTarget.addEventListener('input', this.onFieldInput)
    this.lonFieldTarget.addEventListener('input', this.onFieldInput)

    // If the fields already hold coords, show the marker there.
    this.map.on('load', () => this.syncFromFields())
  }

  disconnect() {
    if (this.onFieldInput) {
      this.latFieldTarget.removeEventListener('input', this.onFieldInput)
      this.lonFieldTarget.removeEventListener('input', this.onFieldInput)
    }
    if (this.map) {
      this.map.remove()
      this.map = null
    }
  }

  placeMarker(lng, lat, writeFields = false) {
    if (this.marker) {
      this.marker.setLngLat([lng, lat])
    } else {
      this.marker = new maplibregl.Marker({ draggable: true, color: '#059669' })
        .setLngLat([lng, lat])
        .addTo(this.map)
      this.marker.on('dragend', () => {
        const p = this.marker.getLngLat()
        this.writeFields(p.lat, p.lng)
      })
    }
    if (writeFields) this.writeFields(lat, lng)
  }

  // Writes back without firing `input`, so it won't loop through onFieldInput.
  writeFields(lat, lng) {
    this.latFieldTarget.value = lat.toFixed(6)
    this.lonFieldTarget.value = lng.toFixed(6)
  }

  syncFromFields() {
    const lat = parseFloat(this.latFieldTarget.value)
    const lng = parseFloat(this.lonFieldTarget.value)
    if (Number.isNaN(lat) || Number.isNaN(lng)) return

    this.placeMarker(lng, lat)
    this.map.flyTo({ center: [lng, lat], zoom: 17, animate: false })
  }
}
