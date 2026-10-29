class Rack::Attack
  # Throttle public contribution submissions by IP to curb spam/abuse of the
  # unauthenticated, file-accepting, email-triggering create endpoint.
  throttle("contributions/ip", limit: 5, period: 10.minutes) do |req|
    req.ip if req.post? && req.path.match?(%r{/mapping/contributions\z})
  end

  # Same for the general "report a problem" form, which also emails staff.
  throttle("reports/ip", limit: 5, period: 10.minutes) do |req|
    req.ip if req.post? && req.path.match?(%r{/reports\z})
  end

  # Active Storage's direct-upload endpoints are mounted by default and need no login,
  # but the app never uses them (all uploads go through our own forms). Left open they
  # let anyone store arbitrary files and then ask libvips to process them.
  blocklist("active_storage/direct_uploads") do |req|
    (req.post? && req.path == "/rails/active_storage/direct_uploads") ||
      (req.put? && req.path.start_with?("/rails/active_storage/disk/"))
  end

  self.throttled_responder = lambda do |_request|
    [ 429, { "Content-Type" => "text/plain" }, [ "Too many submissions. Please try again in a few minutes.\n" ] ]
  end
end

Rails.application.config.middleware.use Rack::Attack
