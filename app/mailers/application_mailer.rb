class ApplicationMailer < ActionMailer::Base
  # The sender must be an address the SMTP server is allowed to send as,
  # so it lives next to the SMTP settings in credentials (smtp.from).
  default from: -> { Rails.application.credentials.dig(:smtp, :from) || "Boolder <hello@boolder.com>" }
  layout "mailer"
end
