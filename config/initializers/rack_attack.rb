class Rack::Attack
  # Throttle public contribution submissions by IP to curb spam/abuse of the
  # unauthenticated, file-accepting, email-triggering create endpoint.
  throttle("contributions/ip", limit: 5, period: 10.minutes) do |req|
    req.ip if req.post? && req.path.match?(%r{/mapping/contributions\z})
  end

  self.throttled_responder = lambda do |_request|
    [ 429, { "Content-Type" => "text/plain" }, [ "Too many submissions. Please try again in a few minutes.\n" ] ]
  end
end

Rails.application.config.middleware.use Rack::Attack
