Bugsnag.configure do |config|
  if Rails.env.local?
    config.enabled_release_stages = []
  else
    config.api_key = Rails.application.credentials.dig(:bugsnag, :api_key)
  end
end
