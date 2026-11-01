require "test_helper"

class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
  setup do
    @area = Area.create!(name: "Bonehill", slug: "bonehill", published: true)
  end

  test "pages send a report-only CSP and an enforced Permissions-Policy" do
    get area_url(@area.slug, locale: :en)
    assert_response :success

    csp = response.headers["Content-Security-Policy-Report-Only"]
    assert csp, "expected a report-only CSP header"
    assert_nil response.headers["Content-Security-Policy"]
    assert_match "script-src 'self'", csp
    assert_match "object-src 'none'", csp
    assert_match "report-uri /csp-violations", csp
    assert_match(/'nonce-[^']+'/, csp)

    assert_match "camera=()", response.headers["Permissions-Policy"]
    assert_match "geolocation=(self)", response.headers["Permissions-Policy"]
  end

  test "every executable inline script carries the page's nonce" do
    get area_url(@area.slug, locale: :en)
    nonce = response.headers["Content-Security-Policy-Report-Only"][/'nonce-([^']+)'/, 1]

    inline = css_select("script:not([src])").reject { |s| s["type"] == "application/ld+json" }
    assert inline.any?
    inline.each { |script| assert_equal nonce, script["nonce"], script.to_html.first(80) }
    assert_no_match(/ on(click|change|load|submit)="/, response.body)
  end

  test "violation reports are logged and acknowledged" do
    report = { "csp-report" => { "document-uri" => "https://example.test/en", "effective-directive" => "script-src",
                                  "blocked-uri" => "inline", "source-file" => "https://example.test/en", "line-number" => 12 } }
    logged = capture_log { post "/csp-violations", params: report.to_json, headers: { "Content-Type" => "application/csp-report" } }

    assert_response :no_content
    assert_match "[CSP] script-src blocked inline on https://example.test/en (https://example.test/en:12)", logged
  end

  test "malformed reports are ignored" do
    post "/csp-violations", params: "not json", headers: { "Content-Type" => "application/csp-report" }
    assert_response :no_content
  end

  private

  def capture_log
    io = StringIO.new
    old = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = old
  end
end
