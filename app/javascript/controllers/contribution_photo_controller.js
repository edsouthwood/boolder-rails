import { Controller } from '@hotwired/stimulus'
import exifr from 'exifr/full'

export default class extends Controller {
  static targets = [
    'previewImage', 'previewContainer', 'canvas', 'linePrompt', 'lineEditor', 'coordsField',
    'latField', 'lonField', 'gpsStatus'
  ]

  connect() {
    this.points = []
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

  setupCanvas() {
    const img = this.previewImageTarget
    const canvas = this.canvasTarget

    const w = img.offsetWidth
    const h = img.offsetHeight

    // Set both attribute size (drawing resolution) and CSS size (display size) to match image
    canvas.width = w
    canvas.height = h
    canvas.style.width = w + 'px'
    canvas.style.height = h + 'px'

    this.points = []
    if (this.hasCoordsFieldTarget) {
      this.coordsFieldTarget.value = ''
    }
    this.redraw()
  }

  addPoint(event) {
    const canvas = this.canvasTarget
    const rect = canvas.getBoundingClientRect()
    const x = parseFloat(((event.clientX - rect.left) / rect.width).toFixed(4))
    const y = parseFloat(((event.clientY - rect.top) / rect.height).toFixed(4))

    this.points.push({ x, y })
    if (this.hasCoordsFieldTarget) {
      this.coordsFieldTarget.value = JSON.stringify(this.points)
    }
    this.redraw()
  }

  undo() {
    this.points.pop()
    if (this.hasCoordsFieldTarget) {
      this.coordsFieldTarget.value = this.points.length > 0 ? JSON.stringify(this.points) : ''
    }
    this.redraw()
  }

  clear() {
    this.points = []
    if (this.hasCoordsFieldTarget) {
      this.coordsFieldTarget.value = ''
    }
    this.redraw()
  }

  redraw() {
    const canvas = this.canvasTarget
    const ctx = canvas.getContext('2d')
    ctx.clearRect(0, 0, canvas.width, canvas.height)

    if (this.points.length === 0) return

    const w = canvas.width
    const h = canvas.height

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
