import { Controller } from '@hotwired/stimulus'
import exifr from 'exifr/full'

// Photo inbox: reads each photo's GPS in the browser, then uploads the photos one
// at a time (no direct upload) and shows how each one went.
export default class extends Controller {
  static targets = ['dropzone', 'list', 'summary', 'queueLink']
  static values = { url: String }

  connect() {
    this.queue = []
    this.busy = false
    this.done = 0
    this.failed = 0
  }

  dragOver(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.add('border-granite', 'bg-gray-50')
  }

  dragLeave() {
    this.dropzoneTarget.classList.remove('border-granite', 'bg-gray-50')
  }

  drop(event) {
    event.preventDefault()
    this.dragLeave()
    this.enqueue(event.dataTransfer.files)
  }

  choose(event) {
    this.enqueue(event.target.files)
    event.target.value = ''
  }

  enqueue(files) {
    for (const file of files) this.queue.push({ file, row: this.addRow(file) })
    this.updateSummary()
    this.processQueue()
  }

  async processQueue() {
    if (this.busy) return
    this.busy = true
    window.addEventListener('beforeunload', this.warnBeforeLeaving)
    while (this.queue.length) {
      const item = this.queue.shift()
      await this.upload(item)
      this.updateSummary()
    }
    window.removeEventListener('beforeunload', this.warnBeforeLeaving)
    this.busy = false
  }

  warnBeforeLeaving(event) {
    event.preventDefault()
    event.returnValue = ''
  }

  async upload({ file, row }) {
    row.status.textContent = 'Reading GPS…'
    const form = new FormData()
    form.append('photo', file)

    let gps = null
    try {
      const position = await exifr.gps(file)
      if (position?.latitude && position?.longitude) {
        gps = position
        form.append('lat', position.latitude)
        form.append('lon', position.longitude)
        const tags = await exifr.parse(file, ['GPSImgDirection'])
        if (tags?.GPSImgDirection != null) form.append('heading', tags.GPSImgDirection)
      }
    } catch (_e) {
      // No readable EXIF: upload without a position
    }

    row.status.textContent = 'Uploading…'
    try {
      const response = await fetch(this.urlValue, {
        method: 'POST',
        headers: {
          'Accept': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content,
        },
        body: form,
      })
      const data = await response.json().catch(() => ({ error: `Upload failed (${response.status})` }))
      if (!response.ok) throw new Error(data.error || `Upload failed (${response.status})`)

      this.done++
      row.status.textContent = [
        gps ? 'GPS found' : 'No GPS',
        data.suggested_boulder_id ? `near boulder #${data.suggested_boulder_id}` : (gps ? 'no boulder within range' : null),
      ].filter(Boolean).join(' · ')
      row.status.className = 'text-xs text-green-700'
      row.link.href = data.edit_url
      row.link.textContent = `Photo #${data.id} →`
      row.link.classList.remove('hidden')
    } catch (error) {
      this.failed++
      row.status.textContent = error.message || 'Upload failed'
      row.status.className = 'text-xs text-red-600'
    }
  }

  addRow(file) {
    const li = document.createElement('li')
    li.className = 'flex items-center gap-3 p-2'

    const img = document.createElement('img')
    img.className = 'w-16 h-12 object-cover rounded bg-gray-100 flex-none'
    img.alt = ''
    img.src = URL.createObjectURL(file)
    img.onload = () => URL.revokeObjectURL(img.src)

    const text = document.createElement('div')
    text.className = 'flex-1 min-w-0'
    const name = document.createElement('p')
    name.className = 'text-sm text-gray-800 truncate'
    name.textContent = file.name
    const status = document.createElement('p')
    status.className = 'text-xs text-gray-500'
    status.textContent = 'Waiting…'
    text.append(name, status)

    const link = document.createElement('a')
    link.className = 'hidden text-sm text-granite hover:underline flex-none'

    li.append(img, text, link)
    this.listTarget.append(li)
    return { status, link }
  }

  updateSummary() {
    const waiting = this.queue.length + (this.busy ? 1 : 0)
    const parts = [`${this.done} uploaded`]
    if (this.failed) parts.push(`${this.failed} failed`)
    if (waiting && this.queue.length) parts.push(`${this.queue.length} waiting`)
    this.summaryTarget.textContent = parts.join(', ')
  }
}
