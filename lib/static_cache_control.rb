# Overrides the blanket far-future `cache-control` that
# `config.public_file_server.headers` applies to everything under `public/`.
#
# That header is correct for digest-stamped assets, but `public/` also holds files
# served under a stable name, where a year-long cache means a change can never
# reach a browser that has already seen the old copy. `service-worker.js` is the
# important one: it is the script that decides what every other request does when
# offline, so it has to stay revalidatable.
#
# Inserted before ActionDispatch::Static so it post-processes that middleware's
# response headers.
class StaticCacheControl
  REVALIDATE = "public, max-age=0, must-revalidate".freeze

  # Files under public/ served at a stable, non-fingerprinted path.
  PATHS = %w[
    /service-worker.js
  ].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    headers["cache-control"] = REVALIDATE if PATHS.include?(env["PATH_INFO"])
    [ status, headers, body ]
  end
end
