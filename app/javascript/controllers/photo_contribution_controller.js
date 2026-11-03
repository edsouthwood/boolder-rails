import { Controller } from '@hotwired/stimulus'
import exifr from 'exifr/full'

// "Add boulder photos": checks each chosen photo in the browser (type, size, landscape,
// GPS and compass heading from EXIF), then on Send uploads them one at a time with the
// form's fields. A photo without GPS that was taken in the last few minutes is placed
// at the phone's current position instead, since the contributor is probably still there.
//
// All sends from one page load share a batch: the server checks the spam captcha (whose
// timestamp is single-use) on the batch's first photo and lets the rest of it through.
export default class extends Controller {
  static targets = ['dropzone', 'input', 'list', 'summary', 'sendButton', 'picker', 'about', 'done', 'doneText']
  static values = { maxSize: Number, types: Array, messages: Object }

  static FRESH_MS = 15 * 60 * 1000
  static DEVICE_ACCURACY_M = 50
  // invisible_captcha refuses a first upload within 4 s of the page loading
  static MIN_PAGE_AGE_MS = 4500

  connect() {
    this.items = []
    this.sending = false
    this.loadedAt = Date.now()
    this.batch = this.uuid()
    this.warnBeforeLeaving = this.warnBeforeLeaving.bind(this)
  }

  disconnect() {
    window.removeEventListener('beforeunload', this.warnBeforeLeaving)
  }

  t(key, vars = {}) {
    return (this.messagesValue[key] || key).replace(/%\{(\w+)\}/g, (_, name) => vars[name] ?? '')
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
    this.add(event.dataTransfer.files)
  }

  choose(event) {
    this.add(event.target.files)
    event.target.value = ''
  }

  add(files) {
    if (this.sending) return
    for (const file of files) {
      const item = { file, ok: false, sent: false }
      item.row = this.addRow(item)
      this.items.push(item)
      item.checked = this.check(item)
    }
    Promise.all(this.items.map((item) => item.checked)).then(() => this.refresh())
    this.refresh()
  }

  // Works out whether a photo can be sent, and where it was taken
  async check(item) {
    const { file } = item
    if (!this.typesValue.includes(file.type)) return this.reject(item, this.t('not_image'))
    if (file.size > this.maxSizeValue) return this.reject(item, this.t('too_big', { size: Math.round(this.maxSizeValue / 1048576) }))

    const size = await this.imageSize(item.row.img)
    if (size && size.height > size.width) return this.reject(item, this.t('portrait'))

    try {
      const gps = await exifr.gps(file)
      if (gps?.latitude && gps?.longitude) {
        item.position = { lat: gps.latitude, lon: gps.longitude, source: 'photo' }
        const tags = await exifr.parse(file, ['GPSImgDirection'])
        if (tags?.GPSImgDirection != null) item.position.heading = tags.GPSImgDirection
      }
    } catch (_e) {
      // No readable EXIF
    }

    if (!item.position && Date.now() - file.lastModified < this.constructor.FRESH_MS && navigator.geolocation) {
      item.wantsDevicePosition = true
    }

    item.ok = true
    this.setStatus(item, item.position ? this.t('gps') : (item.wantsDevicePosition ? this.t('device') : this.t('no_gps')))
  }

  reject(item, message) {
    item.ok = false
    this.setStatus(item, message, 'text-red-600')
  }

  // Browsers apply the EXIF orientation to <img>, so this is the size as it's seen
  imageSize(img) {
    return new Promise((resolve) => {
      if (img.complete && img.naturalWidth) return resolve({ width: img.naturalWidth, height: img.naturalHeight })
      img.addEventListener('load', () => resolve({ width: img.naturalWidth, height: img.naturalHeight }), { once: true })
      img.addEventListener('error', () => resolve(null), { once: true })
    })
  }

  remove(item) {
    if (this.sending || item.sent) return
    this.items = this.items.filter((other) => other !== item)
    item.row.li.remove()
    URL.revokeObjectURL(item.row.img.src)
    this.refresh()
  }

  refresh() {
    const ready = this.items.filter((item) => item.ok && !item.sent)
    this.sendButtonTarget.disabled = this.sending || ready.length === 0
    if (!this.sending) {
      this.summaryTarget.textContent = this.items.length ? this.t('ready', { count: ready.length }) : ''
    }
  }

  async send(event) {
    event.preventDefault()
    await Promise.all(this.items.map((item) => item.checked))
    const queue = this.items.filter((item) => item.ok && !item.sent)
    if (this.sending || queue.length === 0) return

    this.sending = true
    this.refresh()
    window.addEventListener('beforeunload', this.warnBeforeLeaving)

    const wait = this.loadedAt + this.constructor.MIN_PAGE_AGE_MS - Date.now()
    if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait))

    const device = queue.some((item) => item.wantsDevicePosition) ? await this.devicePosition() : null
    let sent = 0
    let failed = 0

    for (const item of queue) {
      this.summaryTarget.textContent = this.t('progress', { done: sent + failed, total: queue.length })
      const result = await this.upload(item, device)
      if (result === 'stop') {
        failed += queue.length - sent - failed
        break
      }
      result ? sent++ : failed++
    }

    window.removeEventListener('beforeunload', this.warnBeforeLeaving)
    this.sending = false
    this.summaryTarget.textContent = failed ? this.t('result_failed', { sent, failed }) : ''
    this.refresh()

    if (sent > 0 && failed === 0) {
      this.doneTextTarget.textContent = this.t('result', { sent })
      this.pickerTarget.classList.add('hidden')
      this.aboutTarget.classList.add('hidden')
      this.sendButtonTarget.parentElement.classList.add('hidden')
      this.doneTarget.classList.remove('hidden')
      this.doneTarget.focus()
    }
  }

  // Returns true when sent, false when this photo failed, 'stop' when no more can be sent
  async upload(item, device) {
    this.setStatus(item, this.t('uploading'))
    const form = new FormData(this.element)
    form.append('photo', item.file)
    form.append('photo_contribution[batch]', this.batch)

    const position = item.position || (item.wantsDevicePosition && device ? { ...device, source: 'device' } : null)
    if (position) {
      form.append('lat', position.lat)
      form.append('lon', position.lon)
      form.append('location_source', position.source)
      if (position.heading != null) form.append('heading', position.heading)
    }

    try {
      const response = await fetch(this.element.action, {
        method: 'POST',
        headers: { 'Accept': 'application/json' },
        body: form,
      })
      const data = await response.json().catch(() => ({}))

      if (response.ok) {
        item.sent = true
        this.setStatus(item, data.boulder ? `${this.t('sent')} · ${this.t('near', { boulder: data.boulder })}` : this.t('sent'), 'text-green-700')
        item.row.removeButton.remove()
        return true
      }
      // The spam check failed (page reopened from history, or another form loaded since):
      // only a fresh page gets past it
      if (data.error === 'too_fast') {
        this.setStatus(item, this.t('reload'), 'text-red-600')
        return 'stop'
      }
      if (response.status === 429) {
        this.setStatus(item, data.error || this.t('failed'), 'text-red-600')
        return 'stop'
      }
      this.setStatus(item, data.error && data.error !== 'rejected' ? data.error : this.t('failed'), 'text-red-600')
      return false
    } catch (_e) {
      this.setStatus(item, this.t('failed'), 'text-red-600')
      return false
    }
  }

  devicePosition() {
    return new Promise((resolve) => {
      navigator.geolocation.getCurrentPosition(
        ({ coords }) => resolve(coords.accuracy <= this.constructor.DEVICE_ACCURACY_M ? { lat: coords.latitude, lon: coords.longitude } : null),
        () => resolve(null),
        { enableHighAccuracy: true, timeout: 15000, maximumAge: 60000 }
      )
    })
  }

  uuid() {
    if (crypto.randomUUID) return crypto.randomUUID()
    const bytes = crypto.getRandomValues(new Uint8Array(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x40
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    const hex = [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('')
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
  }

  reset() {
    this.items.forEach((item) => URL.revokeObjectURL(item.row.img.src))
    this.items = []
    this.listTarget.replaceChildren()
    this.doneTarget.classList.add('hidden')
    this.pickerTarget.classList.remove('hidden')
    this.aboutTarget.classList.remove('hidden')
    this.sendButtonTarget.parentElement.classList.remove('hidden')
    this.refresh()
    this.inputTarget.click()
  }

  warnBeforeLeaving(event) {
    event.preventDefault()
    event.returnValue = ''
  }

  setStatus(item, text, className = 'text-gray-500') {
    item.row.status.textContent = text
    item.row.status.className = `text-xs ${className}`
  }

  addRow(item) {
    const li = document.createElement('li')
    li.className = 'flex items-center gap-3 p-2'

    const img = document.createElement('img')
    img.className = 'w-20 h-14 object-cover rounded bg-gray-100 flex-none'
    img.alt = ''
    img.src = URL.createObjectURL(item.file)

    const text = document.createElement('div')
    text.className = 'flex-1 min-w-0'
    const name = document.createElement('p')
    name.className = 'text-sm text-gray-800 truncate'
    name.textContent = item.file.name
    const status = document.createElement('p')
    status.className = 'text-xs text-gray-500'
    status.textContent = this.t('reading')
    text.append(name, status)

    const removeButton = document.createElement('button')
    removeButton.type = 'button'
    removeButton.className = 'flex-none text-sm text-gray-500 hover:text-red-600 px-2 py-1'
    removeButton.textContent = this.t('remove')
    removeButton.addEventListener('click', () => this.remove(item))

    li.append(img, text, removeButton)
    this.listTarget.append(li)
    return { li, img, status, removeButton }
  }
}
