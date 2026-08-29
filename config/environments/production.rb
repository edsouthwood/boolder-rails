require "active_support/core_ext/integer/time"
require "active_support/core_ext/numeric/bytes"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # ...except the handful of public/ files served under a stable name, which must
  # stay revalidatable (see lib/static_cache_control.rb).
  require Rails.root.join("lib/static_cache_control")
  config.middleware.insert_before ActionDispatch::Static, StaticCacheControl

  # Serve assets and Active Storage proxy URLs (see the cdn_image direct route)
  # from our own host. Upstream pointed this at their CDN (assets.boolder.com).
  config.asset_host = "bowda.edsouthwood.com"

  # Uploaded files live on local disk (backed up by bin/backup). The :amazon
  # service in storage.yml points at the upstream project's S3 bucket.
  config.active_storage.service = :local

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store
  # config.cache_store.connects_to = { database: { writing: :cache } }

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  config.action_mailer.raise_delivery_errors = true

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "bowda.edsouthwood.com", protocol: "https" }

  # Outgoing mail server, configured under the `smtp` key in Rails credentials
  # (address, port, username, password, from). See "Email Setup" in the admin guide.
  smtp = Rails.application.credentials.smtp || {}
  # Port 465 expects TLS from the first byte; other ports (587) upgrade via STARTTLS.
  smtp_implicit_tls = smtp[:port].to_i == 465
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = {
    address: smtp[:address],
    port: smtp[:port] || 587,
    user_name: smtp[:username],
    password: smtp[:password],
    authentication: :plain,
    ssl: smtp_implicit_tls,
    enable_starttls_auto: !smtp_implicit_tls
  }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = [ I18n.default_locale ]

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # localhost is allowed so the app can be smoke-tested directly on the box.
  config.hosts = [ "bowda.edsouthwood.com", "localhost", "127.0.0.1" ]

  # Skip DNS rebinding protection for the default health check endpoint.
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
