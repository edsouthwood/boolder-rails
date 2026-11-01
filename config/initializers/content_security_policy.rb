# Content-Security-Policy: which scripts, styles, images and connections pages may use.
#
# Currently REPORT-ONLY: browsers block nothing, they report what would have been
# blocked to /csp-violations (logged as "[CSP]" in the production log). Once a stretch
# of real traffic reports nothing unexpected, set content_security_policy_report_only
# to false to enforce it. See docs/admin_guide.md, "Content-Security-Policy".

# Hosts the map and editors talk to: base map and fonts, satellite layers in the
# boulder editor, Environment Agency LiDAR, JS module CDNs (es-module-shims fetches
# modules when it has to polyfill import maps), and Bugsnag error reports.
MAP_AND_SERVICE_HOSTS = %w[
  https://tiles.openfreemap.org
  https://server.arcgisonline.com
  https://api.maptiler.com
  https://atlas.microsoft.com
  https://api.mapbox.com
  https://environment.data.gov.uk
  https://cdn.jsdelivr.net
  https://ga.jspm.io
  https://notify.bugsnag.com
  https://sessions.bugsnag.com
].freeze

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.base_uri :self
    policy.object_src :none
    policy.frame_ancestors :self
    policy.form_action :self
    # Inline <script> blocks carry a per-request nonce (javascript_tag nonce: true)
    policy.script_src :self, "https://cdn.jsdelivr.net", "https://ga.jspm.io", "https://d2wy8f7a9ursnm.cloudfront.net"
    # Style attributes and MapLibre's injected styles need 'unsafe-inline' for styles
    policy.style_src :self, :unsafe_inline, "https://cdn.jsdelivr.net"
    # Map tiles, photos (signed Active Storage URLs) and canvas exports
    policy.img_src :self, :data, :blob, :https
    policy.font_src :self, :data
    policy.connect_src :self, *MAP_AND_SERVICE_HOSTS
    # MapLibre runs its tile workers from blob: URLs
    policy.worker_src :self, :blob
    policy.child_src :self, :blob
    policy.manifest_src :self
    policy.frame_src :none
    policy.report_uri "/csp-violations"
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
  config.content_security_policy_report_only = true
end
