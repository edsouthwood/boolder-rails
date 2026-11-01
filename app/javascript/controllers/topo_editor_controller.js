import { Controller } from '@hotwired/stimulus'
import { LINE_RED, pointFromClick, drawDot, drawHold, drawExcludedArea } from 'topo_drawing'

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
    var point = pointFromClick(event, this.canvasTarget)

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
    this.textareaTarget.value = JSON.stringify(this.points)

    this.draw(point, LINE_RED)
  }

  draw(point, color) {
    drawDot(this.canvasContext(), point, color, 8)
  }

  drawHold(point) {
    drawHold(this.canvasContext(), point)
  }

  drawExcludedArea(area) {
    drawExcludedArea(this.canvasContext(), area)
  }

  canvasContext() {
    return this.canvasTarget.getContext("2d")
  }

  redraw() {
    var canvas = this.canvasTarget
    canvas.getContext("2d").clearRect(0, 0, canvas.width, canvas.height)
    this.drawOriginalPoints()
    this.points.forEach(point => this.draw(point, LINE_RED))
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
