# Deployed commit, so Bugsnag can tell which release an error came from.
# Production runs from a git checkout; GIT_REVISION overrides where there's no .git.
Rails.application.config.x.git_revision =
  ENV["GIT_REVISION"].presence ||
  (IO.popen([ "git", "-C", Rails.root.to_s, "rev-parse", "--short", "HEAD" ], err: File::NULL, &:read).strip.presence rescue nil)

Bugsnag.configure do |config|
  if Rails.env.local?
    config.enabled_release_stages = []
  else
    config.api_key = Rails.application.credentials.dig(:bugsnag, :api_key)
    config.app_version = Rails.application.config.x.git_revision
  end

  # Don't send visitors' IP addresses (see the privacy policy). The gem puts the IP
  # in the user id, the request tab's clientIp, and Caddy's forwarding headers.
  config.redacted_keys.merge([ "clientIp", /\Ax-(forwarded-for|real-ip)\z/i ])
  config.add_on_error(proc { |report| report.user.delete("id") })
end
