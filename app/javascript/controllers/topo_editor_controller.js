import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = [ "textarea", "holdsTextarea", "excludedTextarea", "canvas", "container", "image", "form", "viewport", "zoomLabel" ]
  static zoomLevels = [ 1, 2 ]

  connect() {
    this.points = []
    this.originalPoints = this.parsePoints(this.textareaTarget.value)
    this.holds = this.parsePoints(this.holdsTextareaTarget.value)
    // Each not-in area is its own polygon; clicks extend the last one until "New not-in area"
    this.excludedAreas = this.parsePoints(this.excludedTextareaTarget.value)
    this.startNewArea = true
    this.zoom = 1
    this.mode = "line"

    var image = this.imageTarget
    var self = this

    image.onload = function() {
      self.baseWidth = image.naturalWidth/2
      self.baseHeight = image.naturalHeight/2
      self.resize(self.baseWidth * self.zoom, self.baseHeight * self.zoom)
      self.drawOriginalPoints()
    }

    image.src = image.src // hack to trigger image.onload even when the image is cached by the browser
  }

  resize(width, height) {
    var image = this.imageTarget
    var container = this.containerTarget
    var canvas = this.canvasTarget

    image.width = width
    image.height = height
    container.width = width
    container.height = height
    canvas.width = width
    canvas.height = height
  }

  setMode(event) {
    this.mode = event.target.value
  }

  clearHolds(event) {
    event.preventDefault()
    this.holds = []
    this.holdsTextareaTarget.value = ""
    this.redraw()
  }

  zoomIn(event) {
    event.preventDefault()
    this.setZoom(this.constructor.zoomLevels.find(z => z > this.zoom) || this.zoom)
  }

  zoomOut(event) {
    event.preventDefault()
    this.setZoom([...this.constructor.zoomLevels].reverse().find(z => z < this.zoom) || this.zoom)
  }

  // Enlarge the photo and canvas inside the scrolling viewport, keeping the same spot centred
  setZoom(zoom) {
    if (!this.baseWidth || zoom == this.zoom) return

    var viewport = this.viewportTarget
    var centreX = (viewport.scrollLeft + viewport.clientWidth / 2) / viewport.scrollWidth
    var centreY = (viewport.scrollTop + viewport.clientHeight / 2) / viewport.scrollHeight

    this.zoom = zoom
    this.zoomLabelTarget.textContent = zoom + "×"
    this.resize(this.baseWidth * zoom, this.baseHeight * zoom)
    this.redraw()

    viewport.scrollLeft = centreX * viewport.scrollWidth - viewport.clientWidth / 2
    viewport.scrollTop = centreY * viewport.scrollHeight - viewport.clientHeight / 2
  }

  newExcludedArea(event) {
    event.preventDefault()
    this.startNewArea = true
  }

  clearExcludedAreas(event) {
    event.preventDefault()
    this.excludedAreas = []
    this.startNewArea = true
    this.excludedTextareaTarget.value = ""
    this.redraw()
  }

  createPoint(event) {
    var canvas = this.canvasTarget
    var textarea = this.textareaTarget

    var rect = canvas.getBoundingClientRect()
    var x = event.clientX - rect.left
    var y = event.clientY - rect.top

    var percentX = this.limitPrecision(x / rect.width)
    var percentY = this.limitPrecision(y / rect.height)

    var point = {'x': percentX, 'y': percentY }

    if (this.mode == "excluded") {
      if (this.startNewArea) {
        this.excludedAreas.push([])
        this.startNewArea = false
      }
      this.excludedAreas[this.excludedAreas.length - 1].push(point)
      this.excludedTextareaTarget.value = JSON.stringify(this.excludedAreas)
      this.redraw()
      return
    }

    if (this.mode == "holds") {
      this.holds.push(point)
      this.holdsTextareaTarget.value = JSON.stringify(this.holds)
      this.drawHold(point)
      return
    }

    this.points.push(point)
    textarea.value = JSON.stringify(this.points)

    this.draw(point, "#ff2626")
  }

  limitPrecision(value) {
    return parseFloat(value.toFixed(4))
  }

  draw(point, color) {
    // console.log(point.x + ";" + point.y)
    var canvas = this.canvasTarget

    var canvasWidth = canvas.width
    var canvasHeight = canvas.height
    var ctx = canvas.getContext("2d")

    ctx.fillStyle = color
    var pointSize = 8

    ctx.beginPath() //Start path
    ctx.arc(point.x * canvasWidth, point.y * canvasHeight, pointSize, 0, Math.PI * 2, true) // Draw a point using the arc function of the canvas with a point structure.
    ctx.fill() // Close the path and fill.
  }

  drawHold(point) {
    var canvas = this.canvasTarget
    var ctx = canvas.getContext("2d")

    ctx.strokeStyle = "#10b981"
    ctx.lineWidth = 3
    ctx.beginPath()
    ctx.arc(point.x * canvas.width, point.y * canvas.height, 12, 0, Math.PI * 2, true)
    ctx.stroke()
  }

  drawExcludedArea(area) {
    var canvas = this.canvasTarget
    var ctx = canvas.getContext("2d")

    ctx.strokeStyle = "#dc2626"
    ctx.fillStyle = "rgba(220, 38, 38, 0.3)"
    ctx.lineWidth = 2
    ctx.beginPath()
    area.forEach((point, index) => {
      var x = point.x * canvas.width
      var y = point.y * canvas.height
      index == 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)
    })
    ctx.closePath()
    ctx.fill()
    ctx.stroke()
  }

  redraw() {
    var canvas = this.canvasTarget
    canvas.getContext("2d").clearRect(0, 0, canvas.width, canvas.height)
    this.drawOriginalPoints()
    this.points.forEach(point => this.draw(point, "#ff2626"))
  }

  parsePoints(json) {
    try {
      return JSON.parse(json) || []
    } catch (e) {
      return []
    }
  }

  drawOriginalPoints() {
    var self = this

    this.originalPoints.forEach(function (point, index) {
      self.draw(point, "#0000ff")
    })

    this.excludedAreas.forEach(area => this.drawExcludedArea(area))
    this.holds.forEach(point => this.drawHold(point))
  }
}
