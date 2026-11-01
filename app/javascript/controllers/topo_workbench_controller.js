import { Controller } from '@hotwired/stimulus'
import { LINE_RED as RED, pointFromClick, drawDot, drawHold, drawExcludedArea, drawPath } from 'topo_drawing'

// Topo workbench: every line on one photo, drawn and saved without leaving the page.
// Points are stored like the line editor's: { x, y } as fractions of the photo size.

export default class extends Controller {
  static targets = [
    'viewport', 'container', 'image', 'canvas', 'zoomLabel', 'modeRadio',
    'list', 'candidates', 'filter', 'nameField', 'gradeField', 'status', 'saveBtn', 'nextPhoto',
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
      replaceOnClick: !!line.coordinates, // redrawing a drawn line starts it afresh, like the line editor
      newArea: true,
      dirty: false,
    }
    this.selectMode('line') // a new problem always starts with its line, not holds left over from the last one
    this.renderList()
    this.redraw()
    this.setStatus(line.coordinates ? `Editing ${line.name}` : `Drawing ${line.name}: click along the line`)
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
    this.mode = event.target.value
  }

  selectMode(mode) {
    this.mode = mode
    this.modeRadioTargets.forEach(radio => { radio.checked = radio.value === mode })
  }

  click(event) {
    if (!this.draft) return this.setStatus('Pick a problem on the right first.', true)

    const point = pointFromClick(event, this.canvasTarget)
    const draft = this.draft

    if (this.mode === 'holds') {
      draft.holds.push(point)
    } else if (this.mode === 'excluded') {
      if (draft.newArea || !draft.excluded.length) { draft.excluded.push([]); draft.newArea = false }
      draft.excluded[draft.excluded.length - 1].push(point)
    } else {
      if (draft.replaceOnClick) { draft.points = []; draft.replaceOnClick = false }
      draft.points.push(point)
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
    } else draft.points.pop()
    draft.dirty = true
    this.redraw()
  }

  clearMode() {
    const draft = this.draft
    if (!draft) return
    if (this.mode === 'holds') draft.holds = []
    else if (this.mode === 'excluded') { draft.excluded = []; draft.newArea = true }
    else { draft.points = []; draft.replaceOnClick = false }
    draft.dirty = true
    this.redraw()
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
    this.candidates.unshift({ id: line.problem_id, name: line.name, grade: line.grade, near: false, has_line: false })
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
    drawPath(ctx, draft.points, draft.replaceOnClick ? 'rgba(0,0,255,0.7)' : RED, 3)
    draft.points.forEach(point => drawDot(ctx, point, draft.replaceOnClick ? '#0000ff' : RED))
    draft.holds.forEach(point => drawHold(ctx, point))
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

  renderCandidates() {
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
