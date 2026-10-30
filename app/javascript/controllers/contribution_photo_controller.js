import { Controller } from '@hotwired/stimulus'
import exifr from 'exifr/full'

export default class extends Controller {
  static targets = [
    'previewImage', 'previewContainer', 'canvas', 'linePrompt', 'lineEditor', 'coordsField',
    'latField', 'lonField', 'gpsStatus', 'topoThumbnail', 'existingTopoField',
    'holdsField', 'excludedField', 'modeButton', 'modeHint', 'newAreaButton',
    'viewport', 'zoomWrapper', 'zoomLabel'
  ]

  static ZOOM_LEVELS = [1, 2, 3]

  static MAX_HOLDS = 4
  static HOLD_COLOR = '#10b981'
  static MAX_AREAS = 4
  static EXCLUDED_COLOR = '#dc2626'

  connect() {
    this.points = []
    this.holds = []
    // "Not in" polygons; clicks extend the last one until "New area" is pressed
    this.excludedAreas = []
    this.startNewArea = true
    this.mode = 'line'
    this.zoom = 1
  }

  zoomIn() {
    this.setZoom(this.constructor.ZOOM_LEVELS.find(z => z > this.zoom) || this.zoom)
  }

  zoomOut() {
    this.setZoom([...this.constructor.ZOOM_LEVELS].reverse().find(z => z < this.zoom) || this.zoom)
  }

  // Widen the photo inside the scrolling viewport, keeping the same spot centred
  setZoom(zoom) {
    if (!this.hasZoomWrapperTarget || zoom === this.zoom) return

    const viewport = this.viewportTarget
    const centreX = (viewport.scrollLeft + viewport.clientWidth / 2) / viewport.scrollWidth
    const centreY = (viewport.scrollTop + viewport.clientHeight / 2) / viewport.scrollHeight

    this.zoom = zoom
    this.zoomWrapperTarget.style.width = `${zoom * 100}%`
    this.zoomLabelTarget.textContent = `${zoom}×`
    this.resizeCanvas()

    viewport.scrollLeft = centreX * viewport.scrollWidth - viewport.clientWidth / 2
    viewport.scrollTop = centreY * viewport.scrollHeight - viewport.clientHeight / 2
  }

  setMode(event) {
    this.mode = event.currentTarget.dataset.mode
    this.modeButtonTargets.forEach(btn => {
      btn.setAttribute('aria-pressed', btn.dataset.mode === this.mode ? 'true' : 'false')
    })
    if (this.hasModeHintTarget) {
      this.modeHintTarget.textContent = this.modeHintTarget.dataset[`${this.mode}Hint`]
    }
    if (this.hasNewAreaButtonTarget) {
      this.newAreaButtonTarget.classList.toggle('hidden', this.mode !== 'excluded')
    }
  }

  newArea() {
    this.startNewArea = true
  }

  // The array the current mode adds points to (or undoes/clears)
  activePoints() {
    if (this.mode === 'holds') return this.holds
    if (this.mode === 'excluded') return this.excludedAreas[this.excludedAreas.length - 1] || []
    return this.points
  }

  syncFields() {
    if (this.hasCoordsFieldTarget) {
      this.coordsFieldTarget.value = this.points.length > 0 ? JSON.stringify(this.points) : ''
    }
    if (this.hasHoldsFieldTarget) {
      this.holdsFieldTarget.value = this.holds.length > 0 ? JSON.stringify(this.holds) : ''
    }
    if (this.hasExcludedFieldTarget) {
      // Only complete shapes (3+ points) are submitted
      const areas = this.excludedAreas.filter(area => area.length >= 3)
      this.excludedFieldTarget.value = areas.length > 0 ? JSON.stringify(areas) : ''
    }
  }

  async handlePhotoChange(event) {
    const file = event.target.files[0]
    if (!file) return

    // Show photo preview for line drawing
    const url = URL.createObjectURL(file)
    this.lineEditorTarget.classList.remove('hidden')
    this.linePromptTarget.classList.add('hidden')

    this.previewImageTarget.onload = () => {
      this.setupCanvas()
    }
    this.previewImageTarget.src = url

    // Extract GPS from EXIF
    try {
      const gps = await exifr.gps(file)
      if (gps && gps.latitude && gps.longitude) {
        this.latFieldTarget.value = gps.latitude.toFixed(6)
        this.lonFieldTarget.value = gps.longitude.toFixed(6)
        // Notify the location-picker (and any listeners) that coords changed.
        this.latFieldTarget.dispatchEvent(new Event('input', { bubbles: true }))
        this.lonFieldTarget.dispatchEvent(new Event('input', { bubbles: true }))
        this.gpsStatusTarget.textContent = 'GPS location read from photo'
        this.gpsStatusTarget.className = 'text-xs text-emerald-600'
      } else {
        this.gpsStatusTarget.textContent = 'No GPS found in photo — enter manually if known'
        this.gpsStatusTarget.className = 'mt-1 text-xs text-gray-500'
      }
    } catch (_e) {
      // silently ignore EXIF read errors
    }
  }

  selectExistingTopo(event) {
    const btn = event.currentTarget
    const topoId = btn.dataset.topoId
    const mediumUrl = btn.dataset.mediumUrl

    // Toggle deselect
    if (this.hasExistingTopoFieldTarget && this.existingTopoFieldTarget.value === topoId) {
      this.existingTopoFieldTarget.value = ''
      btn.classList.remove('border-emerald-500')
      btn.classList.add('border-transparent')
      this.lineEditorTarget.classList.add('hidden')
      this.linePromptTarget.classList.remove('hidden')
      this.points = []
      this.holds = []
      this.excludedAreas = []
      this.startNewArea = true
      this.syncFields()
      return
    }

    // Deselect any previously selected thumbnail
    this.topoThumbnailTargets.forEach(t => {
      t.classList.remove('border-emerald-500')
      t.classList.add('border-transparent')
    })

    btn.classList.remove('border-transparent')
    btn.classList.add('border-emerald-500')

    if (this.hasExistingTopoFieldTarget) this.existingTopoFieldTarget.value = topoId

    this.lineEditorTarget.classList.remove('hidden')
    this.linePromptTarget.classList.add('hidden')

    this.previewImageTarget.onload = () => { this.setupCanvas() }
    this.previewImageTarget.src = mediumUrl
  }

  // Match the canvas to the photo's displayed size (which changes with zoom) and redraw
  resizeCanvas() {
    const img = this.previewImageTarget
    const canvas = this.canvasTarget

    const w = img.offsetWidth
    const h = img.offsetHeight

    // Set both attribute size (drawing resolution) and CSS size (display size) to match image
    canvas.width = w
    canvas.height = h
    canvas.style.width = w + 'px'
    canvas.style.height = h + 'px'
    this.redraw()
  }

  setupCanvas() {
    this.zoom = 0 // force setZoom(1) to apply
    this.setZoom(1)

    this.points = []
    this.holds = []
    this.excludedAreas = []
    this.startNewArea = true
    this.syncFields()
    this.redraw()
  }

  addPoint(event) {
    const canvas = this.canvasTarget
    const rect = canvas.getBoundingClientRect()
    const x = parseFloat(((event.clientX - rect.left) / rect.width).toFixed(4))
    const y = parseFloat(((event.clientY - rect.top) / rect.height).toFixed(4))

    if (this.mode === 'holds' && this.holds.length >= this.constructor.MAX_HOLDS) return
    if (this.mode === 'excluded' && this.startNewArea) {
      if (this.excludedAreas.length >= this.constructor.MAX_AREAS) return
      this.excludedAreas.push([])
      this.startNewArea = false
    }

    this.activePoints().push({ x, y })
    this.syncFields()
    this.redraw()
  }

  undo() {
    this.activePoints().pop()
    if (this.mode === 'excluded' && this.excludedAreas.length > 0 && this.activePoints().length === 0) {
      this.excludedAreas.pop()
      this.startNewArea = true
    }
    this.syncFields()
    this.redraw()
  }

  clear() {
    if (this.mode === 'excluded') {
      this.excludedAreas = []
      this.startNewArea = true
    } else {
      this.activePoints().length = 0
    }
    this.syncFields()
    this.redraw()
  }

  redraw() {
    const canvas = this.canvasTarget
    const ctx = canvas.getContext('2d')
    ctx.clearRect(0, 0, canvas.width, canvas.height)

    const w = canvas.width
    const h = canvas.height

    ctx.strokeStyle = this.constructor.EXCLUDED_COLOR
    ctx.fillStyle = 'rgba(220, 38, 38, 0.3)'
    ctx.lineWidth = 2
    this.excludedAreas.forEach(area => {
      ctx.beginPath()
      area.forEach((p, i) => i === 0 ? ctx.moveTo(p.x * w, p.y * h) : ctx.lineTo(p.x * w, p.y * h))
      ctx.closePath()
      ctx.fill()
      ctx.stroke()
    })

    ctx.strokeStyle = this.constructor.HOLD_COLOR
    ctx.lineWidth = 3
    this.holds.forEach(p => {
      ctx.beginPath()
      ctx.arc(p.x * w, p.y * h, 10, 0, Math.PI * 2)
      ctx.stroke()
    })

    if (this.points.length === 0) return

    ctx.strokeStyle = '#ff2626'
    ctx.lineWidth = 3
    ctx.lineJoin = 'round'
    ctx.lineCap = 'round'

    ctx.beginPath()
    ctx.moveTo(this.points[0].x * w, this.points[0].y * h)
    for (let i = 1; i < this.points.length; i++) {
      ctx.lineTo(this.points[i].x * w, this.points[i].y * h)
    }
    ctx.stroke()

    this.points.forEach(p => {
      ctx.fillStyle = '#ff2626'
      ctx.beginPath()
      ctx.arc(p.x * w, p.y * h, 5, 0, Math.PI * 2)
      ctx.fill()
    })
  }
}
