// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

// HTTP Basic Auth dialogs only fire for full browser navigations, not fetch().
// Force a real navigation for any /admin path so the auth dialog appears correctly.
document.addEventListener('turbo:before-visit', function(event) {
  if (new URL(event.detail.url).pathname.startsWith('/admin')) {
    event.preventDefault()
    window.location.href = event.detail.url
  }
})