# Receives Content-Security-Policy violation reports from browsers and logs them
# ("[CSP] ..." in the production log). Bodies are capped and nothing is stored.
class CspReportsController < ActionController::Base
  skip_forgery_protection

  MAX_BODY = 16.kilobytes

  def create
    body = request.body.read(MAX_BODY).to_s
    reports(body).first(5).each do |report|
      Rails.logger.warn(
        "[CSP] #{report['effective-directive'] || report['violated-directive'] || report['effectiveDirective']} " \
        "blocked #{report['blocked-uri'] || report['blockedURL']} " \
        "on #{report['document-uri'] || report['documentURL']} " \
        "(#{report['source-file'] || report['sourceFile']}:#{report['line-number'] || report['lineNumber']})"
      )
    end
    head :no_content
  end

  private

  # Old format: {"csp-report": {...}}; Reporting API: [{"type": "csp-violation", "body": {...}}]
  def reports(body)
    json = JSON.parse(body)
    case json
    when Hash then [ json["csp-report"] ].compact.select { |r| r.is_a?(Hash) }
    when Array then json.filter_map { |r| r["body"] if r.is_a?(Hash) && r["body"].is_a?(Hash) }
    else []
    end
  rescue JSON::ParserError
    []
  end
end
