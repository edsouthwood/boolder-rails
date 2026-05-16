import { Controller } from '@hotwired/stimulus'
import exifr from 'exifr/full'

export default class extends Controller {
  static targets = ['gpsSection', 'gpsStatus', 'latField', 'lonField']
  static values = { problemHasLocation: Boolean }

  async handlePhotoChange(event) {
    const file = event.target.files[0]
    if (!file) return

    try {
      const gps = await exifr.gps(file)
      if (gps?.latitude && gps?.longitude) {
        this.latFieldTarget.value = gps.latitude.toFixed(6)
        this.lonFieldTarget.value = gps.longitude.toFixed(6)

        if (!this.problemHasLocationValue) {
          this.gpsSectionTarget.classList.remove('hidden')
          this.gpsStatusTarget.textContent =
            `GPS found in photo: ${gps.latitude.toFixed(5)}, ${gps.longitude.toFixed(5)}`
        }
      }
    } catch (_e) {
      // silently ignore EXIF read errors
    }
  }
}
