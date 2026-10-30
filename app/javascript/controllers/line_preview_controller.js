import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['image', 'canvas']
  static values = { coordinates: Array, holds: Array }

  connect() {
    if (this.hasImageTarget) {
      if (this.imageTarget.complete) {
        requestAnimationFrame(() => this.draw())
      } else {
        this.imageTarget.addEventListener('load', () => this.draw())
      }
    }
  }

  draw() {
    if (!this.hasCanvasTarget || !this.hasImageTarget) return
    const img = this.imageTarget
    const canvas = this.canvasTarget

    const w = img.offsetWidth
    const h = img.offsetHeight
    canvas.width = w
    canvas.height = h

    const ctx = canvas.getContext('2d')

    ctx.strokeStyle = '#10b981'
    ctx.lineWidth = 3
    this.holdsValue.forEach(p => {
      ctx.beginPath()
      ctx.arc(p.x * w, p.y * h, 10, 0, Math.PI * 2)
      ctx.stroke()
    })

    const points = this.coordinatesValue
    if (!points || points.length < 2) return

    ctx.strokeStyle = '#ff2626'
    ctx.lineWidth = 3
    ctx.lineJoin = 'round'
    ctx.lineCap = 'round'

    ctx.beginPath()
    ctx.moveTo(points[0].x * w, points[0].y * h)
    for (let i = 1; i < points.length; i++) {
      ctx.lineTo(points[i].x * w, points[i].y * h)
    }
    ctx.stroke()

    points.forEach(p => {
      ctx.fillStyle = '#ff2626'
      ctx.beginPath()
      ctx.arc(p.x * w, p.y * h, 5, 0, Math.PI * 2)
      ctx.fill()
    })
  }
}
