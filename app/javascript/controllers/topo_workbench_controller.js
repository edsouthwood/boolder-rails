import { Controller } from '@hotwired/stimulus'
import { LINE_RED as RED, NOT_IN_RED, pointFromClick, drawDot, drawHold, drawExcludedArea, drawPath } from 'topo_drawing'

// Topo workbench: every line on one photo, drawn and saved without leaving the page.
// Points are stored like the line editor's: { x, y } as fractions of the photo size.

export default class extends Controller {
  static targets = [
    'viewport', 'container', 'image', 'canvas', 'zoomLabel', 'modeRadio',
    'list', 'candidates', 'suggestions', 'filter', 'guide', 'nameField', 'gradeField', 'status', 'saveBtn', 'nextPhoto',
    'clearBtn', 'removePointBtn',
  ]
  static values = {
    lines: Array, candidates: Array, topoId: Number,
    linesUrl: String, lineUrl: String, quickProblemUrl: String, problemUrl: String,
  }

  connect() {
    this.lines = this.linesValue
    this.candidates = this.candidatesValue
    this.mode = 'line'
    this.zoom = 1
    this.activeIndex = null
    this.draft = null

    this.onKeydown = this.keydown.bind(this)
    this.onBeforeUnload = (event) => { if (this.draft?.dirty) { event.preventDefault(); event.returnValue = '' } }
    document.addEventListener('keydown', this.onKeydown)
    window.addEventListener('beforeunload', this.onBeforeUnload)

    // Line points: drag to move, faint mid-segment dots to add, pick then remove
    const canvas = this.canvasTarget
    canvas.addEventListener('pointerdown', (event) => this.pointerDown(event))
    canvas.addEventListener('pointermove', (event) => this.pointerMove(event))
    canvas.addEventListener('pointerup', (event) => this.pointerUp(event))
    canvas.addEventListener('pointercancel', () => { this.dragging = null })
    // On a touch screen, a finger on a point drags it instead of scrolling the photo
    canvas.addEventListener('touchstart', (event) => {
      const touch = event.touches[0]
      if (touch && this.handleAt(touch.clientX, touch.clientY)) event.preventDefault()
    }, { passive: false })

    const image = this.imageTarget
    image.onload = () => {
      this.baseWidth = image.naturalWidth / 2
      this.baseHeight = image.naturalHeight / 2
      this.resize()
      this.redraw()
    }
    if (image.complete && image.naturalWidth) image.onload()

    this.renderCandidates()
    const firstUndrawn = this.lines.findIndex(line => !line.coordinates)
    if (firstUndrawn >= 0) this.activate(firstUndrawn)
    else this.renderList()
  }

  disconnect() {
    document.removeEventListener('keydown', this.onKeydown)
    window.removeEventListener('beforeunload', this.onBeforeUnload)
  }

  // ─── Choosing a line ─────────────────────────────────────────────────────────

  activate(index) {
    if (index === this.activeIndex) return
    if (this.draft?.dirty && !confirm('Discard the unsaved changes to this line?')) return

    const line = this.lines[index]
    this.activeIndex = index
    this.draft = {
      points: [...(line.coordinates || [])],
      holds: [...(line.start_holds || [])],
      excluded: (line.excluded_areas || []).map(area => [...area]),
      // Clicks add points only while drawing; a drawn line is changed point by point, or
      // started again with Redraw line
      drawing: !line.coordinates,
      picked: null, // the point picked for removal: { path, index } (see paths())
      newArea: true,
      dirty: false,
    }
    this.selectMode('line') // a new problem always starts with its line, not holds left over from the last one
    this.showGuide(line.problem_id)
    this.renderList()
    this.redraw()
    this.setStatus(line.coordinates ? `Editing ${line.name}: drag a point to move it` : `Drawing ${line.name}: click along the line`)
  }

  // Drawing guides (how a problem was drawn on another photo): only the selected problem's,
  // or all of them when it has none
  showGuide(problemId) {
    const mine = this.guideTargets.filter(guide => guide.dataset.problemId === String(problemId))
    this.guideTargets.forEach(guide => { guide.hidden = mine.length > 0 && !mine.includes(guide) })
  }

  nextUndrawn() {
    const count = this.lines.length
    for (let step = 1; step <= count; step++) {
      const index = ((this.activeIndex ?? -1) + step) % count
      if (!this.lines[index].coordinates && index !== this.activeIndex) return this.activate(index)
    }
    this.setStatus('Every problem on this photo has a line.')
  }

  // ─── Drawing ─────────────────────────────────────────────────────────────────

  setMode(event) {
    this.selectMode(event.target.value)
  }

  selectMode(mode) {
    this.mode = mode
    this.modeRadioTargets.forEach(radio => { radio.checked = radio.value === mode })
    if (this.hasClearBtnTarget) {
      this.clearBtnTarget.textContent = { line: 'Redraw line', holds: 'Clear start holds', excluded: 'Clear not-in areas' }[mode]
    }
    if (this.draft) this.draft.picked = null
    this.redraw()
  }

  click(event) {
    // The click that ends a drag or a tap on a point has been dealt with already
    if (this.suppressClick) return
    if (!this.draft) return this.setStatus('Pick a problem on the right first.', true)

    const point = pointFromClick(event, this.canvasTarget)
    const draft = this.draft

    if (this.mode === 'holds') {
      draft.holds.push(point)
    } else if (this.mode === 'excluded') {
      if (draft.newArea || !draft.excluded.length) { draft.excluded.push([]); draft.newArea = false }
      draft.excluded[draft.excluded.length - 1].push(point)
      draft.picked = null
    } else {
      if (!draft.drawing) {
        return this.setStatus('Drag a point to move it, or a faint dot to add one. Redraw line starts the line again.')
      }
      draft.points.push(point)
      draft.picked = null
    }
    draft.dirty = true
    this.redraw()
  }

  undo() {
    const draft = this.draft
    if (!draft) return
    if (this.mode === 'holds') draft.holds.pop()
    else if (this.mode === 'excluded') {
      const last = draft.excluded[draft.excluded.length - 1]
      last?.pop()
      if (last && !last.length) { draft.excluded.pop(); draft.newArea = true }
      draft.picked = null
    } else { draft.points.pop(); draft.picked = null }
    draft.dirty = true
    this.redraw()
  }

  clearMode() {
    const draft = this.draft
    if (!draft) return
    if (this.mode === 'holds') draft.holds = []
    else if (this.mode === 'excluded') { draft.excluded = []; draft.newArea = true; draft.picked = null }
    else {
      draft.points = []
      draft.drawing = true
      draft.picked = null
      this.setStatus('Click along the line from bottom to top to redraw it.')
    }
    draft.dirty = true
    this.redraw()
  }

  // ─── Editing points ──────────────────────────────────────────────────────────
  // In line mode the line's points, in not-in mode each not-in shape's corners: a point can
  // be dragged; a faint dot halfway along each segment adds a point there (drag it, or tap
  // it); a tapped point is picked, then Remove point / Delete removes it (Alt-click removes
  // straight away).

  // What can be edited in this mode: the line (path 'line'), or each not-in shape (path = its
  // index), which is closed, so it also has a mid dot on the edge from its last corner back
  paths() {
    const draft = this.draft
    if (!draft) return []
    if (this.mode === 'line') return [{ path: 'line', points: draft.points, closed: false }]
    if (this.mode === 'excluded') return draft.excluded.map((points, path) => ({ path, points, closed: points.length >= 3 }))
    return []
  }

  pointsOf(path) {
    return path === 'line' ? this.draft.points : this.draft.excluded[path]
  }

  // The point or mid-segment dot under the pointer: { type: 'point' | 'mid', path, index }
  handleAt(clientX, clientY) {
    const rect = this.canvasTarget.getBoundingClientRect()
    const near = (p, radius) => Math.hypot(rect.left + p.x * rect.width - clientX, rect.top + p.y * rect.height - clientY) <= radius
    const paths = this.paths()

    for (const { path, points } of [...paths].reverse()) {
      for (let i = points.length - 1; i >= 0; i--) {
        if (near(points[i], 12)) return { type: 'point', path, index: i }
      }
    }
    for (const shape of paths) {
      for (const i of this.midpointIndexes(shape)) {
        if (near(this.midpoint(shape.points, i), 10)) return { type: 'mid', path: shape.path, index: i }
      }
    }
    return null
  }

  // Segments long enough on screen to show their mid dot (short ones would crowd the points)
  midpointIndexes({ points, closed }) {
    const { width, height } = this.canvasTarget.getBoundingClientRect()
    const indexes = []
    const segments = closed ? points.length : points.length - 1
    for (let i = 0; i < segments; i++) {
      const [a, b] = [points[i], points[(i + 1) % points.length]]
      if (Math.hypot((b.x - a.x) * width, (b.y - a.y) * height) >= 28) indexes.push(i)
    }
    return indexes
  }

  midpoint(points, i) {
    const [a, b] = [points[i], points[(i + 1) % points.length]]
    const round = value => parseFloat(value.toFixed(4))
    return { x: round((a.x + b.x) / 2), y: round((a.y + b.y) / 2) }
  }

  isPicked(path, index) {
    const picked = this.draft?.picked
    return picked != null && picked.path === path && picked.index === index
  }

  pointerDown(event) {
    if (event.button !== 0) return
    const hit = this.handleAt(event.clientX, event.clientY)
    if (!hit) return
    event.preventDefault()
    this.canvasTarget.setPointerCapture?.(event.pointerId)
    this.dragging = { ...hit, startX: event.clientX, startY: event.clientY, moved: false, alt: event.altKey }
  }

  pointerMove(event) {
    const drag = this.dragging
    if (!drag) {
      const hit = this.handleAt(event.clientX, event.clientY)
      const drawingHere = this.mode !== 'line' || this.draft?.drawing
      this.canvasTarget.style.cursor = hit ? (hit.type === 'mid' ? 'copy' : 'move') : (drawingHere ? 'crosshair' : 'default')
      return
    }
    if (!drag.moved && Math.hypot(event.clientX - drag.startX, event.clientY - drag.startY) < 4) return
    drag.moved = true

    const draft = this.draft
    const points = this.pointsOf(drag.path)
    const point = this.clamp(pointFromClick(event, this.canvasTarget))
    if (drag.type === 'mid') {
      // Dragging a mid dot makes it a point, then carries on dragging that
      points.splice(drag.index + 1, 0, point)
      this.dragging = { ...drag, type: 'point', index: drag.index + 1 }
    } else {
      points[drag.index] = point
    }
    draft.picked = null
    draft.dirty = true
    this.redraw()
  }

  pointerUp() {
    const drag = this.dragging
    if (!drag) return
    this.dragging = null
    this.suppressClick = true
    setTimeout(() => { this.suppressClick = false }, 0)

    const draft = this.draft
    if (drag.moved) {
      this.setStatus('Point moved. Enter saves, Esc undoes.')
    } else if (drag.type === 'mid') {
      const points = this.pointsOf(drag.path)
      points.splice(drag.index + 1, 0, this.midpoint(points, drag.index))
      draft.picked = null
      draft.dirty = true
      this.setStatus('Point added. Drag it into place, then Enter saves.')
    } else if (drag.alt) {
      this.removePoint(drag.path, drag.index)
    } else {
      draft.picked = this.isPicked(drag.path, drag.index) ? null : { path: drag.path, index: drag.index }
      if (draft.picked != null) {
        const lastOfShape = drag.path !== 'line' && this.pointsOf(drag.path).length <= 3
        this.setStatus(lastOfShape
          ? 'Point picked: removing it removes this whole not-in area (it needs 3 corners).'
          : 'Point picked: Remove point (or Delete) removes it.')
      }
    }
    this.redraw()
  }

  removePickedPoint() {
    const picked = this.draft?.picked
    if (picked != null) this.removePoint(picked.path, picked.index)
  }

  // A line keeps at least 3 points; a not-in area with 3 corners goes altogether
  removePoint(path, index) {
    const draft = this.draft
    const points = draft && this.pointsOf(path)
    if (!points || index == null || index >= points.length) return
    if (path === 'line') {
      if (points.length <= 3) return this.setStatus('A line needs at least 3 points.', true)
      points.splice(index, 1)
      this.setStatus('Point removed. Enter saves, Esc undoes.')
    } else if (points.length <= 3) {
      draft.excluded.splice(path, 1)
      draft.newArea = true // clicks start a new area rather than extending another one
      this.setStatus('Not-in area removed. Enter saves, Esc undoes.')
    } else {
      points.splice(index, 1)
      this.setStatus('Corner removed. Enter saves, Esc undoes.')
    }
    draft.picked = null
    draft.dirty = true
    this.redraw()
  }

  clamp(point) {
    return { x: Math.min(1, Math.max(0, point.x)), y: Math.min(1, Math.max(0, point.y)) }
  }

  newExcludedArea() {
    if (!this.draft) return
    this.selectMode('excluded')
    this.draft.newArea = true
    this.setStatus('Click round the next not-in area.')
  }

  revert() {
    if (this.activeIndex == null) return
    const index = this.activeIndex
    this.draft = null
    this.activeIndex = null
    this.activate(index)
    this.setStatus('Changes undone.')
  }

  // ─── Saving ──────────────────────────────────────────────────────────────────

  async save() {
    const draft = this.draft
    if (!draft) return
    if (draft.points.length < 3) return this.setStatus('A line needs at least 3 points.', true)

    const line = this.lines[this.activeIndex]
    this.saveBtnTarget.disabled = true
    this.setStatus('Saving…')
    const saved = await this.request('PATCH', this.lineUrl(line.id), {
      line: {
        coordinates: JSON.stringify(draft.points),
        start_holds: draft.holds.length ? JSON.stringify(draft.holds) : '',
        excluded_areas: draft.excluded.filter(area => area.length).length
          ? JSON.stringify(draft.excluded.filter(area => area.length)) : '',
      },
    })
    this.saveBtnTarget.disabled = false
    if (!saved) return

    this.lines[this.activeIndex] = saved
    this.draft.dirty = false
    this.setStatus(`Saved ${saved.name}.`)
    if (this.lines.some(l => !l.coordinates)) {
      this.nextUndrawn()
    } else {
      this.renderList()
      this.redraw()
      this.setStatus(`Saved ${saved.name}. Every problem on this photo has a line.`)
      if (this.hasNextPhotoTarget) this.nextPhotoTarget.focus()
    }
  }

  async addExisting(candidate) {
    if (this.draft?.dirty && !confirm('Discard the unsaved changes to this line?')) return
    if (this.draft) this.draft.dirty = false
    this.setStatus(`Adding ${candidate.name}…`)
    const line = await this.request('POST', this.linesUrlValue, { line: { problem_id: candidate.id, topo_id: this.topoIdValue } })
    if (!line) return
    this.candidates = this.candidates.filter(c => c.id !== candidate.id)
    this.lines.push(line)
    this.renderCandidates()
    this.activate(this.lines.length - 1)
  }

  // Adds every problem on the photo's boulder that isn't on the photo yet, then starts on the first
  async addAllSuggested() {
    const suggested = this.suggested()
    if (!suggested.length) return
    if (this.draft?.dirty && !confirm('Discard the unsaved changes to this line?')) return
    if (this.draft) this.draft.dirty = false

    const firstNew = this.lines.length
    for (const [index, candidate] of suggested.entries()) {
      this.setStatus(`Adding ${index + 1} of ${suggested.length}: ${candidate.name}…`)
      const line = await this.request('POST', this.linesUrlValue, { line: { problem_id: candidate.id, topo_id: this.topoIdValue } })
      if (!line) break // request() has shown the error; keep what was added
      this.candidates = this.candidates.filter(c => c.id !== candidate.id)
      this.lines.push(line)
    }
    this.renderCandidates()
    if (this.lines.length > firstNew) {
      this.activeIndex = null
      this.draft = null
      this.activate(firstNew)
      if (this.lines.length - firstNew === suggested.length) {
        this.setStatus(`Added ${suggested.length}. Drawing ${this.lines[firstNew].name}: click along the line`)
      }
    }
  }

  async quickCreate(event) {
    event.preventDefault()
    const name = this.nameFieldTarget.value.trim()
    if (!name) return
    if (this.draft?.dirty && !confirm('Discard the unsaved changes to this line?')) return
    if (this.draft) this.draft.dirty = false

    this.setStatus(`Creating ${name}…`)
    const line = await this.request('POST', this.quickProblemUrlValue, { name, grade: this.gradeFieldTarget.value })
    if (!line) return
    this.nameFieldTarget.value = ''
    this.gradeFieldTarget.value = ''
    this.lines.push(line)
    this.activate(this.lines.length - 1)
  }

  async remove(index) {
    const line = this.lines[index]
    if (!confirm(`Remove ${line.name} from this photo? Its line here is deleted; the problem stays.`)) return
    const ok = await this.request('DELETE', this.lineUrl(line.id))
    if (ok === null) return

    this.lines.splice(index, 1)
    this.candidates.unshift({ id: line.problem_id, name: line.name, grade: line.grade, near: !!line.on_boulder, has_line: false })
    if (this.activeIndex === index) { this.activeIndex = null; this.draft = null }
    else if (this.activeIndex > index) this.activeIndex--
    this.renderList()
    this.renderCandidates()
    this.redraw()
    this.setStatus(`Removed ${line.name}.`)
  }

  // JSON request; resolves to the parsed body ({} for an empty one), or null after showing the error
  async request(method, url, body) {
    try {
      const response = await fetch(url, {
        method,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content,
        },
        body: body && JSON.stringify(body),
      })
      // A redirect means access was refused (admin pages redirect rather than 403)
      if (response.redirected) throw new Error('Not saved: you may not have access to this area.')
      if (response.status === 204) return {}
      const data = await response.json().catch(() => null)
      if (!response.ok || !data) throw new Error(data?.error || `Not saved (error ${response.status})`)
      return data
    } catch (error) {
      this.setStatus(error.message || 'Network error: not saved', true)
      return null
    }
  }

  // ─── Keyboard ────────────────────────────────────────────────────────────────

  keydown(event) {
    if (event.target.closest('input, textarea, select') || event.metaKey || event.ctrlKey || event.altKey) return
    const actions = {
      Enter: () => this.save(),
      Escape: () => this.revert(),
      z: () => this.undo(),
      Delete: () => this.removePickedPoint(),
      Backspace: () => this.removePickedPoint(),
      n: () => this.nextUndrawn(),
      1: () => this.selectMode('line'),
      2: () => this.selectMode('holds'),
      3: () => this.selectMode('excluded'),
    }
    const action = actions[event.key.length === 1 ? event.key.toLowerCase() : event.key]
    if (!action) return
    // Enter saves even after clicking a drawing-toolbar button (zoom, undo…), but works
    // normally on links and on the sidebar's problem lists and forms
    if (event.key === 'Enter' && event.target.closest('a, aside, form')) return
    event.preventDefault()
    action()
  }

  // ─── Zoom ────────────────────────────────────────────────────────────────────

  zoomIn() { this.setZoom(2) }
  zoomOut() { this.setZoom(1) }

  // Enlarge the photo and canvas inside the scrolling viewport, keeping the same spot centred
  setZoom(zoom) {
    if (!this.baseWidth || zoom === this.zoom) return
    const viewport = this.viewportTarget
    const centreX = (viewport.scrollLeft + viewport.clientWidth / 2) / viewport.scrollWidth
    const centreY = (viewport.scrollTop + viewport.clientHeight / 2) / viewport.scrollHeight

    this.zoom = zoom
    this.zoomLabelTarget.textContent = `${zoom}×`
    this.resize()
    this.redraw()

    viewport.scrollLeft = centreX * viewport.scrollWidth - viewport.clientWidth / 2
    viewport.scrollTop = centreY * viewport.scrollHeight - viewport.clientHeight / 2
  }

  resize() {
    const width = this.baseWidth * this.zoom
    const height = this.baseHeight * this.zoom
    this.imageTarget.width = width
    this.imageTarget.height = height
    this.containerTarget.style.width = `${width}px`
    this.containerTarget.style.height = `${height}px`
    this.canvasTarget.width = width
    this.canvasTarget.height = height
  }

  // ─── Rendering ───────────────────────────────────────────────────────────────

  redraw() {
    const canvas = this.canvasTarget
    const ctx = canvas.getContext('2d')
    ctx.clearRect(0, 0, canvas.width, canvas.height)

    // Other lines faint, so you can see what's already on the photo
    this.lines.forEach((line, index) => {
      if (index === this.activeIndex || !line.coordinates) return
      drawPath(ctx, line.coordinates, 'rgba(0,0,0,0.45)', 5)
      drawPath(ctx, line.coordinates, 'rgba(255,255,255,0.85)', 2.5)
      this.drawLabel(ctx, line.coordinates[0], line.name)
    })

    const draft = this.draft
    if (!draft) return
    draft.excluded.forEach(area => drawExcludedArea(ctx, area))
    drawPath(ctx, draft.points, RED, 3)
    draft.points.forEach(point => drawDot(ctx, point, RED))
    // The handles for this mode: not-in corners as small dots (the line's are drawn above),
    // mid dots, and the picked point's ring
    this.paths().forEach(shape => {
      const color = shape.path === 'line' ? RED : NOT_IN_RED
      if (shape.path !== 'line') shape.points.forEach(point => drawDot(ctx, point, color, 4.5))
      this.midpointIndexes(shape).forEach(i => this.drawMidDot(ctx, this.midpoint(shape.points, i), color))
    })
    const picked = draft.picked && this.pointsOf(draft.picked.path)?.[draft.picked.index]
    if (picked) this.drawPicked(ctx, picked)
    draft.holds.forEach(point => drawHold(ctx, point))
    if (this.hasRemovePointBtnTarget) this.removePointBtnTarget.disabled = draft.picked == null
  }

  // A faint dot halfway along a segment: drag or tap it to add a point
  drawMidDot(ctx, point, color = RED) {
    ctx.fillStyle = 'rgba(255,255,255,0.75)'
    ctx.strokeStyle = color
    ctx.lineWidth = 1.5
    ctx.beginPath()
    ctx.arc(point.x * ctx.canvas.width, point.y * ctx.canvas.height, 4.5, 0, Math.PI * 2)
    ctx.fill()
    ctx.stroke()
  }

  // A ring round the point picked for removal
  drawPicked(ctx, point) {
    ctx.lineWidth = 3
    ctx.strokeStyle = '#ffffff'
    ctx.beginPath()
    ctx.arc(point.x * ctx.canvas.width, point.y * ctx.canvas.height, 11, 0, Math.PI * 2)
    ctx.stroke()
    ctx.lineWidth = 1.5
    ctx.strokeStyle = '#1d4ed8'
    ctx.stroke()
  }

  drawLabel(ctx, point, text) {
    const x = point.x * ctx.canvas.width
    const y = point.y * ctx.canvas.height + 16
    ctx.font = '12px sans-serif'
    ctx.textAlign = 'center'
    ctx.lineWidth = 3
    ctx.strokeStyle = 'rgba(0,0,0,0.7)'
    ctx.strokeText(text, x, y)
    ctx.fillStyle = '#fff'
    ctx.fillText(text, x, y)
  }

  renderList() {
    const list = this.listTarget
    list.replaceChildren()
    if (!this.lines.length) {
      list.append(this.element_('li', 'py-2 text-xs text-gray-400 italic', 'None yet: add one below.'))
      return
    }
    this.lines.forEach((line, index) => {
      const li = this.element_('li', `flex items-center gap-2 py-1.5 ${index === this.activeIndex ? 'bg-amber-50 -mx-3 px-3' : ''}`)
      const pick = this.element_('button', 'flex-1 min-w-0 text-left truncate hover:underline', '')
      pick.type = 'button'
      pick.append(this.element_('span', 'font-medium text-gray-800', line.name))
      if (line.grade) pick.append(this.element_('span', 'ml-1 text-gray-500', line.grade))
      pick.addEventListener('click', () => this.activate(index))

      const state = this.element_('span', `text-xs ${line.coordinates ? 'text-green-700' : 'text-amber-700'}`, line.coordinates ? '✓ drawn' : 'to draw')
      const open = this.element_('a', 'text-xs text-gray-400 hover:text-gray-700', '↗')
      open.href = this.problemUrlValue.replace('__ID__', line.problem_id)
      open.target = '_blank'
      open.title = 'Open problem in a new tab'
      const remove = this.element_('button', 'text-xs text-gray-400 hover:text-red-600', '✕')
      remove.type = 'button'
      remove.title = 'Remove from this photo'
      remove.addEventListener('click', () => this.remove(index))

      li.append(pick, state, open, remove)
      list.append(li)
    })
  }

  // Problems on the photo's boulder (listed on it, or located on its outline) not on the photo yet,
  // in the order they were entered (a problem list's order, usually left to right)
  suggested() {
    return this.candidates.filter(c => c.near).sort((a, b) => a.id - b.id)
  }

  renderSuggestions() {
    if (!this.hasSuggestionsTarget) return
    const box = this.suggestionsTarget
    const suggested = this.suggested()
    box.replaceChildren()
    box.hidden = !suggested.length
    if (!suggested.length) return

    const count = suggested.length
    box.append(this.element_('p', 'text-xs text-amber-900',
      `${count} ${count === 1 ? 'problem' : 'problems'} on ${box.dataset.boulderName} ${count === 1 ? "isn't" : "aren't"} on this photo yet:`))
    const names = this.element_('p', 'text-xs leading-relaxed')
    suggested.forEach((candidate, index) => {
      if (index) names.append(', ')
      const add = this.element_('button', 'text-granite hover:underline', candidate.grade ? `${candidate.name} ${candidate.grade}` : candidate.name)
      add.type = 'button'
      add.title = `Add ${candidate.name} to this photo`
      add.addEventListener('click', () => this.addExisting(candidate))
      names.append(add)
    })
    const all = this.element_('button', 'w-full px-2 py-1 rounded bg-granite text-white hover:bg-granite-dark text-xs font-medium',
      count === 1 ? 'Add it' : `Add all ${count}`)
    all.type = 'button'
    all.addEventListener('click', () => this.addAllSuggested())
    box.append(names, all)
  }

  renderCandidates() {
    this.renderSuggestions()
    const query = this.filterTarget.value.trim().toLowerCase()
    const matches = this.candidates.filter(c => !query || `${c.name} ${c.grade || ''}`.toLowerCase().includes(query))
    const list = this.candidatesTarget
    list.replaceChildren()
    if (!matches.length) {
      list.append(this.element_('li', 'py-2 text-xs text-gray-400 italic', query ? 'No matches.' : 'Every problem in the area is on this photo.'))
      return
    }
    matches.slice(0, 100).forEach(candidate => {
      const li = this.element_('li', '')
      const button = this.element_('button', 'w-full flex items-center gap-2 py-1.5 text-left hover:bg-gray-50')
      button.type = 'button'
      button.append(this.element_('span', 'flex-1 min-w-0 truncate text-gray-800', candidate.name))
      if (candidate.grade) button.append(this.element_('span', 'text-gray-500', candidate.grade))
      if (candidate.near) button.append(this.element_('span', 'text-xs text-green-700', 'on boulder'))
      else if (!candidate.has_line) button.append(this.element_('span', 'text-xs text-amber-700', 'no line'))
      button.addEventListener('click', () => this.addExisting(candidate))
      li.append(button)
      list.append(li)
    })
  }

  element_(tag, className, text) {
    const el = document.createElement(tag)
    if (className) el.className = className
    if (text != null) el.textContent = text
    return el
  }

  lineUrl(id) {
    return this.lineUrlValue.replace('__ID__', id)
  }

  setStatus(message, error = false) {
    this.statusTarget.textContent = message
    this.statusTarget.className = error ? 'text-red-600' : 'text-gray-600'
  }
}
