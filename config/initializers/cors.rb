# Read more: https://github.com/cyu/rack-cors
#
# Note: CORS for static assets (JS, CSS, images) served via assets.boolder.com
# is handled by a CloudFront Response Headers Policy, not here.

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "*"
    resource "/*/admin/map*",
      headers: :any,
      methods: [ :get, :head, :options ]
  end
end
